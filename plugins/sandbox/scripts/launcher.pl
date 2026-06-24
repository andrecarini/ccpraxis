#!/usr/bin/env perl
# launcher.pl — unified `claude-sandbox` launcher (plugins/sandbox/scripts/).
#
# Replaces the duplicated logic that used to live in the launcher
# .sh and .ps1 files. Both are now thin shims that locate perl and
# exec this script.
#
# Responsibilities (mirrored from the original .sh/.ps1 line-for-line):
#   - Arg parsing (positional project-path, --resume-session UUID).
#   - Bootstrap path: if .claude-data doesn't exist, ask the user whether
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

my $LAUNCHER_DIR              = "$PROJECT_PATH/.claude-data/.launcher";
my $SELECTION_FILE            = "$LAUNCHER_DIR/selected-skills.json";
my $MANIFEST_FILE             = "$LAUNCHER_DIR/container-manifest.json";
my $SNAPSHOT_FILE             = "$LAUNCHER_DIR/.discovery-snapshot.json";
my $PLUGINS_SNAPSHOT_FILE     = "$LAUNCHER_DIR/.plugins-snapshot.json";
my $MCP_SNAPSHOT_FILE         = "$LAUNCHER_DIR/.mcp-snapshot.json";
my $SETTINGS_LOCAL_FILE       = "$PROJECT_PATH/.claude/settings.local.json";
my $MATERIALIZED_PLUGINS_FILE = "$LAUNCHER_DIR/installed_plugins.json";
my $SANDBOX_CREDENTIALS_FILE  = "$LAUNCHER_DIR/credentials.json";
# known_marketplaces.json lives under .claude-data/plugins/ (NOT .launcher/)
# so it appears at /root/.claude/plugins/known_marketplaces.json as a real
# file through the parent .claude-data bind — not as a single-file mount.
# Claude Code rewrites the file with write-tmp + rename on every load; a
# file-level bind would reject the rename with EROFS. The parent-bind
# approach lets the rename land naturally; the launcher regenerates the
# file on every launch so in-container mutations are ephemeral, which
# matches the desired "no marketplace state leaks across runs" posture.
my $MATERIALIZED_MARKETPLACES_FILE = "$PROJECT_PATH/.claude-data/plugins/known_marketplaces.json";
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

# =====================================================================
# Bootstrap path (no .claude-data yet)
# =====================================================================
#
# Ask the user whether to set up a new sandbox; on confirm, run the
# perl-driven bootstrap (no agent in the loop). After it returns,
# verify .claude-data was created and continue into the normal launch
# flow.

if (! -d "$PROJECT_PATH/.claude-data") {
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
    if (! -d "$PROJECT_PATH/.claude-data") {
        print STDERR "Bootstrap finished but .claude-data not found. Aborting.\n";
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

my $LOCK_OWNED = 0;

sub acquire_lock {
    my $timeout = 10;
    my $elapsed = 0;
    while (! mkdir $LOCK_DIR) {
        # Already exists. Check for dead PID.
        my $pid_file = "$LOCK_DIR/pid";
        if (-f $pid_file) {
            if (open my $fh, '<', $pid_file) {
                my $owner = <$fh>;
                close $fh;
                chomp $owner if defined $owner;
                if (defined $owner && length $owner) {
                    my $alive;
                    if ($WINDOWS_FAMILY) {
                        # tasklist /FI on Windows; fallback to kill 0 if perl can find the process
                        $alive = kill(0, $owner) ? 1 : 0;
                    } else {
                        $alive = kill(0, $owner) ? 1 : 0;
                    }
                    if (!$alive) {
                        # Stale lock from a crash. Clean up + retry.
                        _rmtree($LOCK_DIR);
                        next;
                    }
                }
            }
        }
        if ($elapsed >= $timeout) {
            print STDERR "ERROR: another claude-sandbox is doing setup for this project (lock held > ${timeout}s at $LOCK_DIR).\n";
            print STDERR "       If you're sure no other launcher is running, delete the lock dir and retry.\n";
            reset_terminal();
            exit 1;
        }
        sleep 1;
        $elapsed++;
    }
    if (open my $fh, '>', "$LOCK_DIR/pid") {
        print $fh $$;
        close $fh;
    }
    $LOCK_OWNED = 1;
}

sub release_lock {
    return unless $LOCK_OWNED;
    _rmtree($LOCK_DIR);
    $LOCK_OWNED = 0;
}

sub _rmtree {
    my $path = shift;
    return unless -e $path;
    require File::Path;
    File::Path::remove_tree($path, { safe => 1, error => \my $err });
    # Best-effort; ignore residual errors.
}

# Signal handlers + END block — exec at the end skips these, so every
# exec path calls release_lock explicitly before exec.
$SIG{INT}  = sub { log_ev('signal', { sig => 'INT' });  LaunchLog::close_log($LAUNCH_LOG); release_lock(); reset_terminal(); exit 130 };
$SIG{TERM} = sub { log_ev('signal', { sig => 'TERM' }); LaunchLog::close_log($LAUNCH_LOG); release_lock(); reset_terminal(); exit 143 };
END { LaunchLog::close_log($LAUNCH_LOG); release_lock() }

acquire_lock();

# B1: open the per-launch log now that the lock is held. Best-effort — a failure
# leaves $LAUNCH_LOG undef and every log_ev() becomes a no-op (the launch still
# runs; it just isn't logged). Manager and connector invocations are separate
# processes, each with its own uniquely-named log file (no double-open).
$LAUNCH_LOG = LaunchLog::open_log("$PROJECT_PATH/.claude-data/sandbox-logs/launch-$LAUNCH_ID.log");
log_ev('launch_start', { project => $PROJECT_PATH, project_name => $PROJECT_NAME, podman => $PODMAN, pid => $$ });

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
    print "Building claude-sandbox image with Claude Code v${HOST_VERSION}...\n";
    log_ev('image_build_start', { version => $HOST_VERSION });
    my $rc = system($PODMAN, 'build',
        '--build-arg', "CLAUDE_VERSION=${HOST_VERSION}",
        '-t', "claude-sandbox:${HOST_VERSION}",
        '-t', 'claude-sandbox:latest',
        $CONTAINER_CONFIG);
    if ($rc != 0) {
        log_ev('image_build_failed', { exit => $rc >> 8 });
        print STDERR "ERROR: podman build failed (exit @{[$rc >> 8]}).\n";
        LaunchLog::close_log($LAUNCH_LOG);
        release_lock();
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

# Ensure base image exists. Capture instead of redirect — `> /dev/null`
# under cmd.exe (native Win32 perl) wouldn't resolve; backticks with
# `2>&1` discard cleanly on all shells.
{
    `$PODMAN image inspect claude-sandbox:latest 2>&1`;
    if ($? != 0) {
        build_image();
    }
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
# Early mode dispatch: CONNECTOR (container already running)
# =====================================================================
#
# If a manager is already up (container is in `running` state), this
# launcher becomes a CONNECTOR. Connectors skip all setup-time work
# (skill picker, staleness check, plugin materialize, backpack
# approval, container create/start, image rebuild prompt) and go
# straight to: session picker → kill-orphan-claudes → exec claude.
#
# The manager terminal is responsible for setup decisions; connectors
# just attach to whatever container the manager built. This also keeps
# discovery / TUI / backpack work out of the connector's terminal,
# where it would be redundant noise (the user already made those
# choices in the manager terminal).
{
    my $state = '';
    if (_container_exists($CONTAINER_NAME)) {
        $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $state if defined $state;
        $state //= '';
    }
    if ($state eq 'running') {
        print "Connecting to running sandbox: $CONTAINER_NAME\n";
        release_lock();
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
        exit $rc;
    }

    # Container missing or stopped. We are the MANAGER for this run.
    # --resume-session only makes sense in connector mode; if we got
    # here with the flag set, there's no running container to attach
    # the resume to.
    if (length $RESUME_SESSION) {
        print STDERR "ERROR: --resume-session $RESUME_SESSION requires the sandbox to already be running.\n";
        print STDERR "       Start the sandbox manager by running `claude-sandbox` in this project (no flags)\n";
        print STDERR "       in another terminal, then re-run this command to attach to the session.\n";
        release_lock();
        reset_terminal();
        exit 1;
    }
}

# =====================================================================
# Perl + sandbox-skills.pl invocation helpers
# =====================================================================

sub run_perl_or_die {
    my ($what, @args) = @_;
    my $rc = system($^X, $SANDBOX_SKILLS_PL, @args);
    if ($rc != 0) {
        print STDERR "ERROR: $what (perl exit @{[$rc >> 8]})\n";
        release_lock();
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
        release_lock();
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
        release_lock();
        reset_terminal();
        exit 0;
    }
    if ($exit != 0) {
        print STDERR "ERROR: select-interactive failed (exit $exit)\n";
        release_lock();
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
        build_image();
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
        release_lock();
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
        release_lock();
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
# Build plugin mounts
# =====================================================================

run_perl_or_die('materialize-plugins failed',
    'materialize-plugins',
    '--selection-file',   $SELECTION_FILE,
    '--plugins-snapshot', $PLUGINS_SNAPSHOT_FILE,
    '--project-path',     $PROJECT_PATH,
    '--output',           $MATERIALIZED_PLUGINS_FILE);

my @PLUGIN_MOUNTS;
if (-d "$HOST_PLUGINS_DIR/cache") {
    push @PLUGIN_MOUNTS, '-v', "$HOST_PLUGINS_DIR/cache:/root/.claude/plugins/cache:ro";
}
push @PLUGIN_MOUNTS, '-v', "$MATERIALIZED_PLUGINS_FILE:/root/.claude/plugins/installed_plugins.json:ro";

# Marketplace registry: materialize a container-shaped copy (paths rewritten,
# directory-source entries dropped) into .claude-data/plugins/. Lives there
# as a real file through the parent .claude-data bind so Claude Code's
# atomic write-tmp+rename pattern works on it — see the
# $MATERIALIZED_MARKETPLACES_FILE definition above for the rationale.
# Plus a RO overlay of the host's marketplaces/ data dir so the rewritten
# installLocation paths resolve to real on-disk marketplace data.
if (-f "$HOST_PLUGINS_DIR/known_marketplaces.json") {
    make_path("$PROJECT_PATH/.claude-data/plugins")
        unless -d "$PROJECT_PATH/.claude-data/plugins";
    run_perl_or_die('materialize-known-marketplaces failed',
        'materialize-known-marketplaces',
        '--output', $MATERIALIZED_MARKETPLACES_FILE);
}
if (-d "$HOST_PLUGINS_DIR/marketplaces") {
    push @PLUGIN_MOUNTS, '-v', "$HOST_PLUGINS_DIR/marketplaces:/root/.claude/plugins/marketplaces:ro";
}

# Bind-mount each directory-source marketplace's source.path INTO the
# container's /root/.claude/plugins/marketplaces/<name>. These mounts
# overlay the parent marketplaces mount above with the actual plugin
# tree, so claude-code can resolve <marketplace>/.claude-plugin/
# marketplace.json and follow each plugin's relative `source` to the
# real code. ccpraxis-local is the canonical example: source.path is
# ~/.claude/ccpraxis/plugins/, which contains .claude-plugin/ +
# backpack/ + beacon/ + sandbox/ + steward/.
#
# materialize-known-marketplaces (above) rewrites these entries'
# source.path AND installLocation to /root/.claude/plugins/marketplaces/
# <name> — same target as these binds, so the JSON references match
# what's on the in-container filesystem.
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
            my $container_path = "/root/.claude/plugins/marketplaces/$name";
            push @PLUGIN_MOUNTS, '-v', "${host_path}:${container_path}:ro";
        }
    }
}

# =====================================================================
# Materialize credentials
# =====================================================================

run_perl_or_die('materialize-credentials failed',
    'materialize-credentials',
    '--output', $SANDBOX_CREDENTIALS_FILE);

# =====================================================================
# Extra env + extra mounts (deploy keys, PAT, SSH commands)
# =====================================================================

my @EXTRA_ENV;
my @EXTRA_MOUNTS;

if (-f "$PROJECT_PATH/.claude-data/git-ssh-command.sh") {
    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=/root/.claude/git-ssh-command.sh';
} elsif (-f "$PROJECT_PATH/deploy_key") {
    push @EXTRA_ENV, '-e', 'GIT_SSH_COMMAND=ssh -i /project/deploy_key -o StrictHostKeyChecking=no';
}

if (-f "$PROJECT_PATH/.claude-data/git-askpass.sh") {
    push @EXTRA_MOUNTS, '-v', "$PROJECT_PATH/.claude-data/git-askpass.sh:/root/.claude/git-askpass.sh:ro";
    push @EXTRA_MOUNTS, '-v', "$PROJECT_PATH/.claude-data/git-pat:/root/.claude/git-pat:ro";
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
    push @EXTRA_MOUNTS, '-v', "$PROJECT_PATH/.claude-data/git-credential-pat.sh:/root/.claude/git-credential-pat.sh:ro";
    push @EXTRA_MOUNTS, '-v', "$PROJECT_PATH/.claude-data/gitconfig:/root/.config/git/config:ro";
}

if (-f "$PROJECT_PATH/.claude-data/git-ssh-command.sh") {
    push @EXTRA_MOUNTS, '-v', "$PROJECT_PATH/.claude-data/git-ssh-command.sh:/root/.claude/git-ssh-command.sh:ro";
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

if (! -f "$PROJECT_PATH/.claude-data/.claude.json"
    && -f "$CONTAINER_CONFIG/claude.json") {
    _copy_file("$CONTAINER_CONFIG/claude.json", "$PROJECT_PATH/.claude-data/.claude.json");
}

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
    my $sessions_dir = "$PROJECT_PATH/.claude-data/projects/-project";
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
# Host data layout (.claude-data) + blueprint application
# =====================================================================
#
# /root/.claude inside the container is a direct bind mount of the host's
# <project>/.claude-data/. Session jsonl, tasks/, lockfiles, settings.json,
# CLAUDE.md, .credentials.json, .launcher/ — all are live host files. No
# podman cp round-trips, no seed-on-create, no rescue. The host filesystem
# IS the state.
#
# On container create we ensure the launcher's canonical copies of CLAUDE.md
# / settings.json / .credentials.json live at .claude-data/ on the host so
# they appear at /root/.claude/{CLAUDE.md,settings.json,.credentials.json}
# inside the container. Same for /root/.claude.json (which lives at
# /root/, not /root/.claude/) — bind-mounted as a single-file mount from
# .claude-data/.claude.json.
#
# Historical: from the first sandbox version through 2026-06, /root/.claude
# was backed by a podman xfs volume to dodge two Hyper-V 9p bugs (O_APPEND
# EIO + utimensat silent-fail). The WSL2 backend's /mnt/c bind honors both
# correctly, so the volume + sync-sidecar architecture was retired.
# Reintroduce ONLY if a future backend's host-bind fails the t/01
# (O_APPEND, utimensat UTIME_NOW, utimensat explicit-timestamp) probes.

sub apply_blueprints_to_host_data {
    my $host_data = "$PROJECT_PATH/.claude-data";
    make_path($host_data) unless -d $host_data;
    if (-f $CONTAINER_CLAUDE_MD) {
        _copy_file($CONTAINER_CLAUDE_MD, "$host_data/CLAUDE.md");
    }
    if (-f $CONTAINER_SETTINGS_JSON) {
        _copy_file($CONTAINER_SETTINGS_JSON, "$host_data/settings.json");
    }
    # .credentials.json is NOT copied here — it's bind-mounted as a
    # single-file bind from $LAUNCHER_DIR/credentials.json directly,
    # so writes from inside the container (mcpOAuth tokens during
    # `claude mcp add` auth) land on the canonical host file and persist
    # across container rebuild without a sync step.
}

# Single-file bind mounts require the host path to exist before podman
# create — otherwise podman silently creates a directory at the host
# path and the in-container mount target becomes a directory too.
# These helpers ensure each single-file bind has a host file to point at.

sub ensure_claude_json_host_file {
    my $host_json = "$PROJECT_PATH/.claude-data/.claude.json";
    return if -f $host_json;
    my $host_data = "$PROJECT_PATH/.claude-data";
    make_path($host_data) unless -d $host_data;
    open(my $fh, '>', $host_json) or do {
        print STDERR "WARNING: couldn't create $host_json: $!\n";
        return;
    };
    close $fh;
}

sub ensure_credentials_json_host_file {
    return if -f $SANDBOX_CREDENTIALS_FILE;
    make_path($LAUNCHER_DIR) unless -d $LAUNCHER_DIR;
    open(my $fh, '>', $SANDBOX_CREDENTIALS_FILE) or do {
        print STDERR "WARNING: couldn't create $SANDBOX_CREDENTIALS_FILE: $!\n";
        return;
    };
    # Empty file would fail claude's JSON parse. Seed minimal valid JSON
    # — claude-code overwrites with full structure on first auth.
    print $fh "{}\n";
    close $fh;
}

# Materialize the git credential helper (+ an additive global git config) used
# for HTTPS PAT auth. Claude Code's Bash tool scrubs GIT_ASKPASS from the
# environment, so the env-based askpass is dead for any git the agent runs; a
# credential helper read from a git CONFIG FILE is immune to that scrub. The
# helper emits GitHub creds from the PAT mounted at ~/.claude/git-pat. It is
# scoped to https://github.com in the config (the PAT is a GitHub fine-grained
# token — never hand it to other hosts) and no-ops when no PAT file is present.
# Both files live in .claude-data (already bind-mounted to /root/.claude); the
# config is additionally mounted at the XDG path /root/.config/git/config by
# the caller. Rewritten every launch so the logic stays current and pre-fix
# sandboxes heal. The host source files exist before `podman create` so the
# single-file binds don't auto-create directories.
sub ensure_git_credential_helper {
    my $cd = "$PROJECT_PATH/.claude-data";
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
    print "Killed orphan claude(s).\n\n";
}

# Run claude inside the container. Returns claude's exit code.
#
# Host's .claude-data IS the live state via the bind mount, so claude's
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
    print "Starting container: $CONTAINER_NAME\n";
} else {
    print "Creating new container: $CONTAINER_NAME\n";
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

    my @podman_args = (
        $PODMAN, 'create', '-it',
        '--name',     $CONTAINER_NAME,
        '--hostname', 'claude-sandbox',
        # 9000-9009: published AND socat-bridged in the container entrypoint
        # (0.0.0.0:N -> 127.0.0.1:N), so loopback-bound listeners like Claude
        # Code's OAuth callback receiver are reachable from the host browser.
        '-p',         '9000-9009:9000-9009',
        # 9010-9019: published but deliberately NOT bridged. Nothing squats
        # these, so a server can bind 0.0.0.0:N directly and be host-reachable
        # with no socat to evict. Use for dev servers / emulators that bind
        # the wildcard address themselves (the common case).
        '-p',         '9010-9019:9010-9019',
        # Sandbox-marker env var that skill guards inside the container key
        # off (instead of fragile $HOME-path sniffing). Stable across any
        # future image-internal user/path changes.
        '-e',         'CLAUDE_SANDBOX=1',
    );
    push @podman_args, @EXTRA_ENV;
    push @podman_args,
        '-v', "${PROJECT_PATH}:/project",
        # /root/.claude is a direct bind from host's .claude-data/.
        # On WSL2 (and Linux/macOS hosts), the bind honors O_APPEND and
        # utimensat correctly — claude's session jsonl appends, task
        # store, lock manager, and settings writes all work as expected
        # with no volume + sync-sidecar workaround. See the "Host data
        # layout" comment block earlier in this file for history.
        '-v', "${PROJECT_PATH}/.claude-data:/root/.claude",
        # .launcher is OVERLAID as RO on top of the .claude-data bind.
        # The directory is launcher-managed metadata (hashes, snapshots,
        # blueprint canonicals, container-created/-name) — a compromised
        # in-container process could otherwise fake hashes to bypass
        # backpack approval or corrupt the launcher's selection state.
        # statusline.pl + skills/plugins read its contents; nothing
        # inside the container needs to write to it.
        '-v', "${LAUNCHER_DIR}:/root/.claude/.launcher:ro",
        # .credentials.json is a single-file RW bind from the canonical
        # location inside .launcher/. The container DOES need to write
        # here (mcpOAuth tokens written by `claude mcp add` flows), and
        # binding the single file lets those writes land on the canonical
        # path so they survive container rebuild — without exposing the
        # rest of .launcher/ as writable. ensure_credentials_json_host_file()
        # seeds an empty {} if missing.
        '-v', "${SANDBOX_CREDENTIALS_FILE}:/root/.claude/.credentials.json",
        # .claude.json lives at /root/.claude.json (NOT inside
        # /root/.claude/), so it gets its own single-file bind from
        # .claude-data/.claude.json. ensure_claude_json_host_file() above
        # guarantees the host file exists so the mount doesn't auto-create
        # a directory.
        '-v', "${PROJECT_PATH}/.claude-data/.claude.json:/root/.claude.json",
        '-v', "${CLAUDE_HOST_CONFIG}/ccpraxis/scripts/statusline.pl:/root/.claude/statusline.pl:ro";
    push @podman_args, @SKILL_MOUNTS;
    push @podman_args, @PLUGIN_MOUNTS;
    push @podman_args, @EXTRA_MOUNTS;
    push @podman_args, @BACKPACK_MOUNTS;
    push @podman_args, 'claude-sandbox:latest';

    # Rewrite every `-v HOST:CONTAINER[:opts]` pair into `--mount type=bind,…`
    # to defeat MSYS2's `:`-as-path-list mangling on Git-for-Windows perl.
    @podman_args = convert_v_to_mount(@podman_args);

    my $rc = system(@podman_args);
    log_ev('container_create', { exit => $rc >> 8, container => $CONTAINER_NAME });
    if ($rc != 0) {
        print STDERR "ERROR: podman create failed (exit @{[$rc >> 8]}) — not committing baseline.\n";
        release_lock();
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
    # We scan the two paths that hold every host-side `-v` target (.claude-data
    # and .claude-data/.launcher); a `;C` entry in either is unambiguous evidence.
    {
        my @stray;
        for my $dir ("$PROJECT_PATH/.claude-data", $LAUNCHER_DIR) {
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
            print STDERR "ERROR: MSYS2 path corruption detected after podman create.\n";
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
            release_lock();
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

my $BACKPACK_APPROVED      = 0;
my $BACKPACK_TRUST_FILE    = "$LAUNCHER_DIR/backpack-trusted-hash";
my $BACKPACK_HOST_FILE     = "$PROJECT_PATH/.claude-data/backpack.json";
my $BACKPACK_HOST_HASH;
my $BACKPACK_HOST_PL       = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/backpack/scripts/backpack.pl";

if ($CONTAINER_WAS_CREATED && -f $BACKPACK_HOST_FILE) {
    if (! -f $BACKPACK_HOST_PL) {
        print STDERR "WARNING: backpack.json present but host backpack.pl missing at $BACKPACK_HOST_PL\n";
        print STDERR "         Skipping install pass; run /backpack:install in-session after fixing.\n";
    } else {
        # Validate using host's perl — same backpack.pl, host-resident file.
        my $validate_rc = system($^X, $BACKPACK_HOST_PL, 'validate', $BACKPACK_HOST_FILE);
        if ($validate_rc != 0) {
            print STDERR "\n";
            print STDERR "WARNING: backpack.json failed schema validation (see errors above).\n";
            print STDERR "         Skipping install pass. Fix the file (or delete it) and re-launch.\n";
            print STDERR "\n";
        } else {
            $BACKPACK_HOST_HASH = md5_of_file($BACKPACK_HOST_FILE);
            my $trusted_hash;
            if (-f $BACKPACK_TRUST_FILE) {
                $trusted_hash = _read_file($BACKPACK_TRUST_FILE);
                chomp $trusted_hash if defined $trusted_hash;
            }
            my $is_first_time = !defined $trusted_hash;
            my $is_changed    = defined $trusted_hash && $trusted_hash ne $BACKPACK_HOST_HASH;

            print "\n";
            print "Backpack found for this project:\n";
            system($^X, $BACKPACK_HOST_PL, 'list', $BACKPACK_HOST_FILE);
            print "\n";

            if ($is_first_time) {
                print "WARNING: this backpack has not been approved on this machine before — it may have\n";
                print "         shipped with the cloned project rather than being authored by you.\n";
                print "WARNING: the install/verify commands above will run AS ROOT inside the container.\n";
                print "         Review every one before approving.\n";
                print "\n";
            } elsif ($is_changed) {
                print "NOTE: backpack.json changed since last approval (likely via in-session /backpack:add).\n";
                print "      Re-confirming approval.\n";
                print "\n";
            }

            my $default_yes = !$is_first_time;
            my $prompt = $default_yes
                ? "Install backpack items now? [Y/n]: "
                : "Install backpack items now? [y/N]: ";
            print $prompt;
            my $choice = <STDIN>;
            $choice //= '';
            chomp $choice;
            my $first = lc(substr($choice, 0, 1) // '');
            $BACKPACK_APPROVED = $default_yes ? ($first ne 'n') : ($first eq 'y');

            if (!$BACKPACK_APPROVED) {
                print "Skipping backpack install pass. Re-run anytime in-session via /backpack:install.\n";
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
release_lock();
my $start_rc = system($PODMAN, 'start', $CONTAINER_NAME);
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

# Bind mount of .claude-data → /root/.claude means host filesystem IS
# the live state. No seed, no rescue, no sync. Blueprint files were
# already materialized to .claude-data/ before podman create — the bind
# now exposes them in the container at the canonical paths. Same for
# .claude.json's single-file bind. Nothing to do here.

# --- Backpack install (container side, only if approved up-front) ---
# All user interaction (validate, list, prompt) happened on the host
# before `podman start`. By this point the decision is made — commit the
# trusted hash and run apt + install in the running container.
#
# Large backpack installs (e.g. chromium = 289 deps / 221MB) can easily
# exceed the container's 5-min HB window, which would otherwise let the
# entrypoint loop reap the container mid-`apt-get install`. We solve
# that by running apt-get update + the install + a parallel heartbeat
# refresher all under a single `podman exec bash`. The heartbeat runs as
# a background subshell tied to the bash's lifetime via `trap EXIT`, so
# it dies the moment the install completes (or this bash is signalled).
# Single exec → single lifecycle → no orphan helper to clean up.
if ($BACKPACK_APPROVED) {
    # Record the trusted hash NOW (before install). If install
    # itself fails some items, the user has still approved this
    # specific content — a re-launch shouldn't re-warn.
    _write_file($BACKPACK_TRUST_FILE, $BACKPACK_HOST_HASH);
    # Pre-flight: confirm the container has perl + backpack.pl wired in.
    # If the mount didn't land (older ccpraxis checkout, missing source),
    # we warn and skip — claude still launches.
    my $has_perl = (system($PODMAN, 'exec', $CONTAINER_NAME,
        'test', '-x', '/usr/bin/perl') == 0);
    my $has_helper = $has_perl
        && (system($PODMAN, 'exec', $CONTAINER_NAME,
            'test', '-f', '/root/.claude/backpack.pl') == 0);
    if (!$has_helper) {
        print STDERR "WARNING: Backpack found at .claude-data/backpack.json but backpack.pl isn't mounted in the container. Update ccpraxis (the launcher needs the plugin's backpack/scripts/backpack.pl) and rebuild.\n";
    } else {
        # Inline bash script: kick off the heartbeat refresher in the
        # background, run apt-get update + backpack install in the
        # foreground, then let the EXIT trap kill the refresher on the
        # way out. The script's exit status mirrors the install's.
        # Note: apt-get update failures are not fatal (per the pre-existing
        # behavior — some backpack entries don't depend on apt), so its
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
perl /root/.claude/backpack.pl install /root/.claude/backpack.json
BASH
        my $install_rc = system($PODMAN, 'exec', $CONTAINER_NAME,
            'bash', '-c', $install_script);
        if ($install_rc != 0) {
            print "\n";
            print "WARNING: Some backpack items failed (see above). Handing off to claude anyway — fix in-session via /backpack:add, /backpack:remove, or by editing the backpack file directly and running /backpack:install.\n";
            print "\n";
        }
    }
}

# =====================================================================
# Heartbeat loop (manager mode)
# =====================================================================
#
# Container is up + backpack install (if any) is done. This launcher
# now becomes the heartbeat keeper: refresh /tmp/.launcher-alive every
# 2 minutes (well within the container's 5-minute HB staleness window).
# Closing this terminal — or sending Ctrl+C — stops the refresh; the
# container reaps itself within ~5 minutes.
#
# To start a claude session, the user runs `claude-sandbox` in another
# terminal — that one hits the CONNECTOR branch above.

# Refresh sentinel one more time before entering the BEAT_INTERVAL sleep,
# so the first $BEAT_INTERVAL window starts from "now" — covers the case
# where the install pass took a long time and its last in-container
# refresh was already a while ago.
system($PODMAN, 'exec', $CONTAINER_NAME, 'touch', '/tmp/.launcher-alive');

print "\n";
print "=" x 60 . "\n";
print "Sandbox ready: $CONTAINER_NAME\n";
print "=" x 60 . "\n";
print "Open another terminal in this project and run:\n";
print "    claude-sandbox\n";
print "to start or resume a claude session.\n";
print "\n";
print "Multiple connector terminals can share this sandbox.\n";
print "This terminal is the manager — keep it open. Closing it stops\n";
print "the sandbox (~5 minutes after the last heartbeat).\n";
print "Press Ctrl+C to stop now.\n";
print "\n";

log_ev('manager_ready', { container => $CONTAINER_NAME });

my $BEAT_INTERVAL = 120;  # Container's HB is 300 (5 min); 120s gives 2.5x margin.
while (1) {
    sleep $BEAT_INTERVAL;
    my $rc = system($PODMAN, 'exec', $CONTAINER_NAME, 'touch', '/tmp/.launcher-alive');
    if ($rc != 0) {
        # Heartbeat failed — most likely cause is the container died
        # (was rm'd from another terminal, podman machine restarted,
        # something killed conmon). Confirm by inspecting state and
        # exit cleanly if so.
        my $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
        chomp $state if defined $state;
        $state //= '';
        if ($state ne 'running') {
            log_ev('container_gone', { state => $state, container => $CONTAINER_NAME });
            print STDERR "\n";
            print STDERR "Container $CONTAINER_NAME is no longer running (state: '$state').\n";
            print STDERR "Manager exiting.\n";
            reset_terminal();
            exit 0;
        }
        # Container IS still running but exec failed — log and keep trying.
        log_ev('heartbeat_fail', { exit => $rc >> 8, state => $state });
        printf STDERR "[%s] WARNING: heartbeat refresh failed (exit %d); will retry next tick\n",
            strftime("%H:%M:%S", localtime), ($rc >> 8);
        next;
    }
    log_ev('heartbeat', {});
    printf "[%s] heartbeat\n", strftime("%H:%M:%S", localtime);
}
