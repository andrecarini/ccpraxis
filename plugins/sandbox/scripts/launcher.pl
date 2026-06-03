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

# Call podman.exe explicitly on Windows. Defensive: if any installer ever
# drops an extensionless `podman` shell-wrapper alongside `podman.exe` (as
# Docker Desktop historically did with `docker`), Git-for-Windows perl's
# Unix-style PATH search would find the wrapper first and fail when it can't
# resolve `sh` from the Windows PATH it inherits. Naming the .exe directly
# sidesteps any such wrapper hijacking.
my $PODMAN = $WINDOWS_FAMILY ? 'podman.exe' : 'podman';

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
my $SYNC_SIDECAR_PL   = "$SANDBOX_PLUGIN/scripts/sync-sidecar.pl";
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
# Container CLAUDE.md and settings.json: per-project copies (blueprint
# model). Container can modify these freely; changes never propagate
# back to ccpraxis. Drift from upstream is detected via stored hash;
# user picks rebuild to refresh.
my $CONTAINER_CLAUDE_MD       = "$LAUNCHER_DIR/container-CLAUDE.md";
my $CONTAINER_SETTINGS_JSON   = "$LAUNCHER_DIR/container-settings.json";
my $CLAUDE_MD_HASH_FILE       = "$LAUNCHER_DIR/.container-CLAUDE-md-hash";
my $SETTINGS_HASH_FILE        = "$LAUNCHER_DIR/.container-settings-json-hash";
my $LOCK_DIR                  = "$LAUNCHER_DIR/.launcher.lock";

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
$SIG{INT}  = sub { release_lock(); reset_terminal(); exit 130 };
$SIG{TERM} = sub { release_lock(); reset_terminal(); exit 143 };
END { release_lock() }

acquire_lock();

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
    return md5_of_file("$CONTAINER_CONFIG/Containerfile");
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
    my $rc = system($PODMAN, 'build',
        '--build-arg', "CLAUDE_VERSION=${HOST_VERSION}",
        '-t', "claude-sandbox:${HOST_VERSION}",
        '-t', 'claude-sandbox:latest',
        $CONTAINER_CONFIG);
    if ($rc != 0) {
        print STDERR "ERROR: podman build failed (exit @{[$rc >> 8]}).\n";
        release_lock();
        reset_terminal();
        exit 1;
    }
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

# Named volume that backs /root/.claude/projects inside the container.
# Reason: on Windows Podman/HyperV the host bind mount is a 9p filesystem
# that rejects O_APPEND writes with EIO. Claude Code's session resume opens
# the session jsonl in append mode, so resume fails every time. A podman
# named volume lives in the in-machine xfs filesystem (not 9p) and supports
# the full POSIX mode set. The launcher syncs host<->volume around each
# claude run, so the host bind mount remains the source of truth for
# backup/visibility but isn't on the critical write path.
my $SESSIONS_VOLUME = "${CONTAINER_NAME}-sessions";

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
if (-f "$HOST_PLUGINS_DIR/known_marketplaces.json") {
    push @PLUGIN_MOUNTS, '-v', "$HOST_PLUGINS_DIR/known_marketplaces.json:/root/.claude/plugins/known_marketplaces.json:ro";
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
}

if (-f "$PROJECT_PATH/.claude-data/git-ssh-command.sh") {
    push @EXTRA_MOUNTS, '-v', "$PROJECT_PATH/.claude-data/git-ssh-command.sh:/root/.claude/git-ssh-command.sh:ro";
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
# Sessions-volume helpers (9p O_APPEND workaround)
# =====================================================================
#
# See the SESSIONS_VOLUME comment near the top of this file for why we
# overlay a named volume on /root/.claude/projects.
#
# The mount target /root/.claude/projects is INSIDE /root/.claude (which
# is itself a 9p bind from the host). The volume mount overlays that
# subdir — claude sees the volume contents at that path, not the host
# bind contents. We sync host<->volume around each claude run so the host
# stays the source of truth for backup + inspection.
#
# Same idea for ~/.claude.json: it's a file-level 9p bind and also breaks
# on O_APPEND. We stop bind-mounting it on container create; instead the
# launcher seeds the container's copy from host before claude runs and
# syncs it back after.

sub ensure_sessions_volume {
    # `podman volume create` is NOT idempotent — it returns exit 125 with
    # "volume already exists" on collision. Inspect first; only create when
    # the volume is genuinely missing. Output of the create call is silenced
    # so we don't leak a stray volume name into stdout on the create path.
    `$PODMAN volume inspect "$SESSIONS_VOLUME" 2>&1`;
    return if $? == 0;
    my $captured = `$PODMAN volume create "$SESSIONS_VOLUME" 2>&1`;
    if ($? != 0) {
        print STDERR "ERROR: failed to create podman volume $SESSIONS_VOLUME: $captured\n";
        release_lock();
        reset_terminal();
        exit 1;
    }
}

# Probe whether the sessions volume currently has any contents. Run as
# `podman exec` against the named container, which already has the volume
# mounted at /root/.claude/projects. Returns 1 = empty, 0 = has content.
sub sessions_volume_is_empty {
    my $check = `$PODMAN exec "$CONTAINER_NAME" sh -c "test -z \\"\$(ls -A /root/.claude/projects 2>/dev/null)\\"" 2>/dev/null`;
    return $? == 0 ? 1 : 0;
}

# Copy host's .claude-data/projects/. into the container's volume mount.
# Used only on first container creation when the volume is empty — never
# during a restart (volume already holds the latest from prior runs) and
# never mid-session (would clobber in-flight writes).
sub seed_sessions_volume_from_host {
    my $host_projects = "$PROJECT_PATH/.claude-data/projects";
    return unless -d $host_projects;
    print "Seeding sessions volume from host...\n";
    my $rc = system($PODMAN, 'cp', "$host_projects/.",
                    "${CONTAINER_NAME}:/root/.claude/projects/");
    if ($rc != 0) {
        print STDERR "WARNING: failed to seed sessions volume (exit @{[$rc >> 8]}). Resume may not find existing sessions.\n";
    }
}

# Copy host's ~/.claude.json into the container. We stopped bind-mounting
# it (since 9p breaks any append claude does on this file). The container's
# overlay fs holds the file across container restarts; rebuilds wipe it
# (handled by re-seeding here).
sub seed_claude_json_from_host {
    my $host_json = "$PROJECT_PATH/.claude-data/.claude.json";
    return unless -f $host_json;
    my $rc = system($PODMAN, 'cp', $host_json, "${CONTAINER_NAME}:/root/.claude.json");
    if ($rc != 0) {
        print STDERR "WARNING: failed to seed ~/.claude.json (exit @{[$rc >> 8]}).\n";
    }
}

# Mirror volume contents back to host. Called on every clean claude exit —
# host bind mount remains the durable record. `podman cp` traverses the
# podman API directly (NOT through the 9p mount), so the post-sync writes
# don't hit the O_APPEND-broken path.
sub sync_sessions_volume_to_host {
    my $host_projects = "$PROJECT_PATH/.claude-data/projects";
    make_path($host_projects) unless -d $host_projects;
    my $rc = system($PODMAN, 'cp', "${CONTAINER_NAME}:/root/.claude/projects/.",
                    "$host_projects/");
    if ($rc != 0) {
        print STDERR "WARNING: failed to sync sessions to host (exit @{[$rc >> 8]}). Host's .claude-data/projects/ may be stale until next sync.\n";
    }
}

sub sync_claude_json_to_host {
    my $host_json = "$PROJECT_PATH/.claude-data/.claude.json";
    # Best-effort; absent file in container = nothing to sync.
    my $rc = system($PODMAN, 'cp', "${CONTAINER_NAME}:/root/.claude.json", $host_json);
    if ($rc != 0) {
        print STDERR "WARNING: failed to sync ~/.claude.json to host (exit @{[$rc >> 8]}).\n";
    }
}

# Spawn the periodic sync sidecar as a background child. The sidecar polls
# `kill 0, parent_pid` so it self-exits if this launcher dies abnormally
# (terminal force-close, kill -9, etc.) — otherwise stray sidecars would
# accumulate. Returns the child PID, or 0 if fork failed (in which case we
# fall back to start/exit syncs only).
sub spawn_sync_sidecar {
    my $pid = fork();
    if (!defined $pid) {
        print STDERR "WARNING: fork failed: $!. Periodic sync disabled; final sync only.\n";
        return 0;
    }
    if ($pid == 0) {
        # Child. Exec into the sidecar script so we don't double-up on
        # launcher state (locks, signal handlers, etc.).
        exec($^X, $SYNC_SIDECAR_PL,
            '--container',     $CONTAINER_NAME,
            '--host-projects', "$PROJECT_PATH/.claude-data/projects",
            '--host-json',     "$PROJECT_PATH/.claude-data/.claude.json",
            '--parent-pid',    $$,
            '--interval',      '60') or do {
            print STDERR "sidecar exec failed: $!\n";
            POSIX::_exit(1);
        };
    }
    return $pid;
}

sub stop_sync_sidecar {
    my $pid = shift;
    return unless $pid && $pid > 0;
    kill 'TERM', $pid;
    # Brief grace period for clean shutdown before reaping. waitpid with
    # WNOHANG keeps us from blocking if the sidecar hung; in that case the
    # END block at process exit cleans it up.
    require POSIX;
    for (1 .. 5) {
        my $r = waitpid($pid, POSIX::WNOHANG());
        return if $r > 0;
        sleep 1;
    }
    kill 'KILL', $pid;
    waitpid($pid, 0);
}

# Run claude inside the container with concurrent periodic sync, then do a
# final sync on exit. Replaces the prior exec() call sites — we need our
# perl process alive both DURING the run (to host the sidecar) and AFTER
# (to do the final sync). Returns claude's exit code.
sub run_claude_with_sync {
    my @cmd = @_;
    my $sidecar = spawn_sync_sidecar();
    my $rc = system(@cmd);
    stop_sync_sidecar($sidecar);
    # Final guaranteed sync after the sidecar is dead, so we don't race with
    # it on the same podman cp.
    sync_sessions_volume_to_host();
    sync_claude_json_to_host();
    # Drop the heartbeat sentinel so the container's wait loop exits on
    # its next poll (~3s) rather than waiting 120s for the sentinel to
    # go stale. Best-effort: ignore errors (container may already be gone).
    system($PODMAN, 'exec', $CONTAINER_NAME, 'rm', '-f', '/tmp/.launcher-alive');
    return $rc >> 8;
}

# =====================================================================
# Resolve session decision UP-FRONT
# =====================================================================
#
# The container's CMD is a bash keep-alive loop that exits ~15s after the
# last `claude` process leaves. If we ran the picker AFTER `podman start`,
# user think-time would let that 15s window expire and the subsequent
# `podman exec` would fail with "container state improper". Pick first,
# touch the container second — that way the gap between `podman start`
# (or the existence check) and `podman exec` is sub-second.
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
        release_lock();
        reset_terminal();
        exit 0;
    }
    push @SESSION_FLAGS, '--resume', $uuid if $action eq 'resume';
    # else 'new' — no flags, claude starts fresh.
}

# =====================================================================
# Launch or reattach
# =====================================================================
#
# Tracks whether this run created a new container (incl. via [r]ebuild).
# The backpack install pass below only fires on fresh creation — on a
# restart of an existing (stopped) container, tooling state was preserved
# and re-running the install pass would just be slow no-op (verify-then-
# skip on every item).

my $CONTAINER_WAS_CREATED = 0;

if (_container_exists($CONTAINER_NAME)) {
    my $state = `$PODMAN inspect --format '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null`;
    chomp $state if defined $state;
    $state //= '';
    if ($state eq 'running') {
        print "Container $CONTAINER_NAME is already running - starting a new session inside it.\n";
        release_lock();
        my @cmd = ($PODMAN, 'exec', '-it', $CONTAINER_NAME,
                   'claude', '--dangerously-skip-permissions',
                   @SESSION_FLAGS);
        # Run + post-sync. Can't exec() here anymore: we need the perl
        # process alive after claude exits so it can mirror the sessions
        # volume + .claude.json back to host. See run_claude_with_sync.
        my $rc = run_claude_with_sync(@cmd);
        reset_terminal();
        exit $rc;
    }
    # Container exists but stopped — start it below.
    print "Starting container: $CONTAINER_NAME\n";
} else {
    print "Creating new container: $CONTAINER_NAME\n";

    # Materialize blueprint copies on first create.
    if (! -f $CONTAINER_CLAUDE_MD) {
        _copy_file("$CONTAINER_CONFIG/CLAUDE.md", $CONTAINER_CLAUDE_MD);
        _write_file($CLAUDE_MD_HASH_FILE, md5_of_file("$CONTAINER_CONFIG/CLAUDE.md"));
    }
    if (! -f $CONTAINER_SETTINGS_JSON) {
        _copy_file("$CONTAINER_CONFIG/settings.json", $CONTAINER_SETTINGS_JSON);
        _write_file($SETTINGS_HASH_FILE, md5_of_file("$CONTAINER_CONFIG/settings.json"));
    }

    # Create the named sessions volume before referencing it in `podman
    # create -v`. Idempotent — exists across container rebuilds, so a fresh
    # container picks up the prior run's sessions automatically.
    ensure_sessions_volume();

    my @podman_args = (
        $PODMAN, 'create', '-it',
        '--name',     $CONTAINER_NAME,
        '--hostname', 'claude-sandbox',
        '-p',         '9000-9009:9000-9009',
        # Sandbox-marker env var that skill guards inside the container key
        # off (instead of fragile $HOME-path sniffing). Stable across any
        # future image-internal user/path changes.
        '-e',         'CLAUDE_SANDBOX=1',
    );
    push @podman_args, @EXTRA_ENV;
    push @podman_args,
        '-v', "${PROJECT_PATH}:/project",
        '-v', "${PROJECT_PATH}/.claude-data:/root/.claude",
        '-v', "${LAUNCHER_DIR}:/root/.claude/.launcher:ro",
        '-v', "${SANDBOX_CREDENTIALS_FILE}:/root/.claude/.credentials.json",
        '-v', "${CONTAINER_CLAUDE_MD}:/root/.claude/CLAUDE.md",
        '-v', "${CONTAINER_SETTINGS_JSON}:/root/.claude/settings.json",
        '-v', "${CLAUDE_HOST_CONFIG}/ccpraxis/scripts/statusline.pl:/root/.claude/statusline.pl:ro",
        # 9p-O_APPEND workaround: overlay /root/.claude/projects with a named
        # volume backed by the machine's xfs filesystem. The host bind below
        # /root/.claude is still 9p — that's fine for the rest of the tree
        # (claude rewrites those files via O_TRUNC, not appends). Sessions
        # specifically use O_APPEND, which 9p rejects with EIO. See the
        # SESSIONS_VOLUME comment near the top of this file for the chain.
        # NOTE: ~/.claude.json USED to be a file-level 9p bind here; it was
        # removed for the same reason (claude appends to it during resume).
        # Launcher now seeds + syncs it via podman cp instead.
        '-v', "${SESSIONS_VOLUME}:/root/.claude/projects";
    push @podman_args, @SKILL_MOUNTS;
    push @podman_args, @PLUGIN_MOUNTS;
    push @podman_args, @EXTRA_MOUNTS;
    push @podman_args, @BACKPACK_MOUNTS;
    push @podman_args, 'claude-sandbox:latest';

    # Rewrite every `-v HOST:CONTAINER[:opts]` pair into `--mount type=bind,…`
    # to defeat MSYS2's `:`-as-path-list mangling on Git-for-Windows perl.
    @podman_args = convert_v_to_mount(@podman_args);

    my $rc = system(@podman_args);
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
# The container's keep-alive bash CMD exits 15s after the last `claude`
# process is gone. If we did validate / list / prompt AFTER `podman
# start`, the user's read-and-press-y time would burn through that window
# and the subsequent `podman exec apt-get update` would fail with
# "container state improper". Run all the interaction up here on the
# host (using the host's backpack.pl — it's the same script that gets
# mounted into the container), capture the approval, and only do the
# in-container install after start. The gap between `podman start` and
# the first `podman exec` then stays sub-second.

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
system($PODMAN, 'start', $CONTAINER_NAME);

# Land the keep-alive heartbeat immediately. The container's wait loop
# starts a 5-second grace timer at boot; after that it requires either
# `claude` running OR /tmp/.launcher-alive freshly mtime-touched (last
# 120s). The sync sidecar (started below) refreshes the sentinel every
# 60s; this touch buys the first window before the sidecar's first tick.
system($PODMAN, 'exec', $CONTAINER_NAME, 'touch', '/tmp/.launcher-alive');

# --- Seed sessions volume + ~/.claude.json from host (on fresh create only) ---
# Only seed on fresh container creation. On restart of an existing container,
# the volume already holds the most-recent sessions from the prior run, and
# the container's overlay holds the most-recent .claude.json. Re-seeding
# either would clobber work; only happens when we've definitively just made
# a new empty container.
if ($CONTAINER_WAS_CREATED) {
    if (sessions_volume_is_empty()) {
        seed_sessions_volume_from_host();
    } else {
        print "Sessions volume already populated (carried over from prior container) - skipping seed.\n";
    }
    seed_claude_json_from_host();
}

# --- Backpack install (container side, only if approved up-front) ---
# All user interaction (validate, list, prompt) happened on the host
# before `podman start` to keep the post-start gap sub-second. By this
# point the decision is made — just commit the trusted hash and run
# apt + install in the running container, fast and unattended.
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
        print "Refreshing apt index...\n";
        # apt-get update is idempotent; we run it once so individual
        # backpack entries don't each need to. Failure is not fatal —
        # some entries (e.g. project-setup category) don't need apt.
        system($PODMAN, 'exec', $CONTAINER_NAME,
            'apt-get', 'update', '-qq');
        print "Installing backpack items...\n";
        my $install_rc = system($PODMAN, 'exec', $CONTAINER_NAME,
            'perl', '/root/.claude/backpack.pl', 'install',
            '/root/.claude/backpack.json');
        if ($install_rc != 0) {
            print "\n";
            print "WARNING: Some backpack items failed (see above). Handing off to claude anyway — fix in-session via /backpack:add, /backpack:remove, or by editing the backpack file directly and running /backpack:install.\n";
            print "\n";
        }
    }
}

my @exec_cmd = ($PODMAN, 'exec', '-it', $CONTAINER_NAME,
                'claude', '--dangerously-skip-permissions',
                @SESSION_FLAGS);
# Run + post-sync (mirrors volume + .claude.json back to host). Can't
# exec() here anymore — see run_claude_with_sync for rationale.
my $rc = run_claude_with_sync(@exec_cmd);
reset_terminal();
exit $rc;
