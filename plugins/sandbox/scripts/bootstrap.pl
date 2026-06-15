#!/usr/bin/env perl
# bootstrap.pl — interactive bootstrap for `claude-sandbox`
# (plugins/sandbox/scripts/).
#
# Invoked by launcher.pl on first launch in a project (when `.claude-data/`
# is absent and the user confirms the bootstrap prompt). Performs what the
# old `/sandbox` skill used to do — deterministic, perl-driven, no agent
# in the loop.
#
# Steps (mirrors the legacy skill's 7-step flow, minus the redundant
# "tell user to run claude-sandbox" since the launcher continues
# automatically after this script returns):
#
#   1. Verify container-config (plugins/sandbox/container/) exists.
#   2. Build the container image if not already built (requires Docker or Podman — auto-detected).
#   3. Create the project's `.claude-data/` directory.
#   4. Append `.claude-data` and `deploy_key` to `.gitignore`.
#   5. Git auth setup (auto-detect remote, prompt for PAT/SSH key).
#   6. Wire `claude-sandbox` into PATH via the install hook.
#
# Returns 0 on success, non-zero on failure or user-abort.
#
# Usage: perl bootstrap.pl [--project-path PATH]
#   (default project path: cwd)

use strict;
use warnings;
use File::Path qw(make_path);
use File::Basename qw(basename);
use Cwd qw(abs_path);

binmode STDOUT, ':raw';
binmode STDERR, ':raw';

# Detect docker OR podman — both are supported. Prefer docker if both
# present (more widely installed). Use `<cli> --version` exit code as the
# probe; PATH-lookup heuristics get fooled on Windows by extensionless
# shell-wrapper shims (Docker Desktop historically dropped one alongside
# docker.exe that Git-for-Windows perl's POSIX PATH search would find
# first and fail to spawn). Always name the .exe explicitly.
my $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;
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
my $RUNTIME_NAME = ($PODMAN =~ /docker/) ? 'docker' : 'podman';

# Disable MSYS2 argument-path conversion (see launcher.pl for full reason).
# Short version: MSYS2 translates argv elements containing colons as PATH-
# like lists and re-joins them with `;`, which mangles podman `-v` mount
# specs. Set MSYS2_ARG_CONV_EXCL=* so args go through verbatim. We then
# hand-translate `/c/foo` → `C:/foo` ourselves via `winify_path` so podman.exe
# can resolve build contexts (it does NOT auto-translate POSIX paths).
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $WINDOWS_FAMILY;

# Convert MSYS2/Git-Bash POSIX path (`/c/Users/...`) to Windows form
# (`C:/Users/...`). No-op for paths that already start with a drive letter,
# and for non-Windows platforms.
sub winify_path {
    my $p = shift;
    return $p unless defined $p && length $p;
    return $p unless $WINDOWS_FAMILY;
    $p =~ s|^/([a-zA-Z])/|$1:/|;
    return $p;
}

# =====================================================================
# Arg parsing
# =====================================================================

my $PROJECT_PATH;
{
    my @argv = @ARGV;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--project-path') {
            die "ERROR: --project-path needs a value\n" unless @argv;
            $PROJECT_PATH = shift @argv;
        } elsif ($a =~ /^--project-path=(.*)$/) {
            $PROJECT_PATH = $1;
        } elsif ($a eq '--help' || $a eq '-h') {
            print "Usage: $0 [--project-path PATH]\n";
            exit 0;
        } else {
            die "ERROR: unknown arg '$a'\n";
        }
    }
}

$PROJECT_PATH //= Cwd::getcwd();
$PROJECT_PATH = abs_path($PROJECT_PATH)
    or die "ERROR: cannot resolve project path\n";
$PROJECT_PATH =~ s|\\|/|g;
$PROJECT_PATH =~ s|/+$||;
$PROJECT_PATH = winify_path($PROJECT_PATH);

# =====================================================================
# Constants
# =====================================================================

my $HOME = $ENV{HOME} // $ENV{USERPROFILE}
    or die "ERROR: neither HOME nor USERPROFILE is set\n";
$HOME =~ s|\\|/|g;
$HOME =~ s|/+$||;
$HOME = winify_path($HOME);

my $CLAUDE_HOST_CONFIG = "$HOME/.claude";
my $SANDBOX_PLUGIN     = "$CLAUDE_HOST_CONFIG/ccpraxis/plugins/sandbox";
my $CONTAINER_CONFIG   = "$SANDBOX_PLUGIN/container";
my $CCPRAXIS_INSTALL_PL = "$SANDBOX_PLUGIN/ccpraxis-install.pl";

# =====================================================================
# Small UI helpers
# =====================================================================

sub prompt_yn {
    my ($msg, $default) = @_;
    $default //= 'n';
    my $hint = lc($default) eq 'y' ? '[Y/n]' : '[y/N]';
    print "$msg $hint: ";
    my $ans = <STDIN>;
    chomp $ans if defined $ans;
    return lc($default) eq 'y' if !defined $ans || !length $ans;
    return lc(substr($ans, 0, 1)) eq 'y';
}

sub prompt_choice {
    my ($msg, @options) = @_;
    print "$msg\n";
    for my $i (0 .. $#options) {
        printf "  [%d] %s\n", $i + 1, $options[$i];
    }
    while (1) {
        printf "Choice [1-%d]: ", scalar @options;
        my $ans = <STDIN>;
        chomp $ans if defined $ans;
        return undef unless defined $ans;
        if ($ans =~ /^\d+$/ && $ans >= 1 && $ans <= @options) {
            return $ans - 1;  # 0-based
        }
        print "  Invalid choice, try again.\n";
    }
}

sub prompt_line {
    my ($msg, $allow_empty) = @_;
    while (1) {
        print "$msg: ";
        my $ans = <STDIN>;
        return undef unless defined $ans;
        chomp $ans;
        return $ans if length $ans || $allow_empty;
        print "  Empty input not allowed, try again.\n";
    }
}

sub log_step {
    my $msg = shift;
    print "\n>>> $msg\n";
}

sub log_ok    { print "    OK    $_[0]\n" }
sub log_skip  { print "    SKIP  $_[0]\n" }
sub log_done  { print "    DONE  $_[0]\n" }
sub log_warn  { print STDERR "    WARN  $_[0]\n" }
sub log_error { print STDERR "    ERROR $_[0]\n" }

sub die_bootstrap {
    my $msg = shift;
    print STDERR "\nBOOTSTRAP FAILED: $msg\n";
    exit 1;
}

# =====================================================================
# Step 1: verify container-config
# =====================================================================

log_step("Step 1/6: verify container-config");
unless (-f "$CONTAINER_CONFIG/Containerfile") {
    die_bootstrap("$CONTAINER_CONFIG/Containerfile not found — install ccpraxis first.");
}
log_ok("Containerfile present");

unless (-f "$CONTAINER_CONFIG/claude.json") {
    log_warn("claude.json template missing; creating a minimal one.");
    my $minimal = <<'JSON';
{
  "hasCompletedOnboarding": true,
  "lastOnboardingVersion": "99.0.0",
  "numStartups": 1,
  "hasSeenTasksHint": true,
  "hasSeenStashHint": true
}
JSON
    open my $fh, '>:raw', "$CONTAINER_CONFIG/claude.json"
        or die_bootstrap("cannot write claude.json template: $!");
    print $fh $minimal;
    close $fh;
    log_done("wrote $CONTAINER_CONFIG/claude.json");
} else {
    log_ok("claude.json template present");
}

# =====================================================================
# Step 2: ensure container runtime is reachable, then build the image
# =====================================================================

log_step("Step 2/6: ensure $RUNTIME_NAME is reachable and the container image exists");

# Preflight: confirm the runtime is reachable AND its backend is up.
# `<cli> info` is the canonical "actually working?" probe — on Windows
# with Podman it confirms the podman machine is running; with Docker
# Desktop it confirms the daemon is up; on Linux it confirms the user
# has access to the runtime. Bare `--version` (already done at detection)
# would pass even if the backend is stopped.
{
    my $info_output = `$PODMAN info --format '{{.Host.Arch}}' 2>&1`;
    if ($? != 0) {
        print STDERR "\n";
        print STDERR "ERROR: $RUNTIME_NAME is installed but the backend is not reachable.\n";
        print STDERR "       Tried: $PODMAN info\n";
        print STDERR "       Output:\n";
        for my $line (split /\r?\n/, ($info_output // '')) {
            print STDERR "         $line\n";
        }
        print STDERR "\n";
        if ($RUNTIME_NAME eq 'docker') {
            print STDERR "       Start Docker Desktop (or `systemctl start docker` on Linux), then re-run.\n";
        } elsif ($WINDOWS_FAMILY) {
            print STDERR "       On Windows, ensure Podman Desktop is running OR run:\n";
            print STDERR "           podman machine init --provider wsl   # first time only — USE WSL2, NOT HYPER-V\n";
            print STDERR "           podman machine start\n";
            print STDERR "\n";
            print STDERR "       ⚠  HYPER-V BACKEND IS NOT SUPPORTED. Microsoft's 9p host-share silently\n";
            print STDERR "          breaks O_APPEND (claude session resume fails with EIO) and utimensat\n";
            print STDERR "          (Bun's lock manager wedges → TUI freezes every ~60s). WSL2 is the\n";
            print STDERR "          only reliable Windows backend for both docker and podman.\n";
        } else {
            print STDERR "       Start the podman backend (`podman machine start` on macOS,\n";
            print STDERR "       or check the rootless socket on Linux).\n";
        }
        print STDERR "\n";
        die_bootstrap("$RUNTIME_NAME backend not reachable — see above");
    }
    log_ok("$RUNTIME_NAME is reachable");

    # ⚠  Hyper-V backend detection — actively block bootstrap on this
    # configuration. We learned this the hard way over three days of
    # debugging "claude resume fails with EIO" and "TUI freezes after
    # ~60s of work". See the WSL2 migration plan + the sandbox README
    # historical-context callout for the full autopsy.
    #
    # Podman 5+ exposes the provider in `podman info`. Docker doesn't
    # report its WSL/Hyper-V status the same way, but Docker Desktop on
    # Windows has used WSL2 by default since 2021 — if someone manages
    # to put it on Hyper-V they'll have done so knowingly. So we only
    # block podman + hyperv automatically; we don't try to probe Docker.
    if ($WINDOWS_FAMILY && $RUNTIME_NAME eq 'podman') {
        my $machine_list = `$PODMAN machine list --format '{{.Name}} {{.VMType}}' 2>&1`;
        if ($? == 0 && $machine_list =~ /\bhyperv\b/i) {
            print STDERR "\n";
            print STDERR "ERROR: detected a podman machine running on the Hyper-V provider.\n";
            print STDERR "       Listing:\n";
            for my $line (split /\r?\n/, ($machine_list // '')) {
                next unless length $line;
                print STDERR "         $line\n";
            }
            print STDERR "\n";
            print STDERR "       ⚠  HYPER-V BACKEND IS NOT SUPPORTED. Microsoft's `Plan9FileServer`\n";
            print STDERR "          (the 9p host-share used by Hyper-V) silently breaks two syscalls\n";
            print STDERR "          claude/Bun depend on:\n";
            print STDERR "            - O_APPEND writes return EIO   → `claude --resume` fails\n";
            print STDERR "            - utimensat silently no-ops    → Bun lock manager wedges, TUI freezes\n";
            print STDERR "          Symptom: 'claude seems to work but stops responding after ~60s'.\n";
            print STDERR "\n";
            print STDERR "       Fix: rebuild the podman machine on WSL2:\n";
            print STDERR "         podman machine stop   podman-machine-default\n";
            print STDERR "         podman machine rm -f  podman-machine-default\n";
            print STDERR "         podman machine init --provider wsl --cpus 4 --memory 3584\n";
            print STDERR "         podman machine start\n";
            print STDERR "\n";
            print STDERR "       Prerequisites for WSL2: in admin PowerShell,\n";
            print STDERR "         Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux\n";
            print STDERR "         Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform\n";
            print STDERR "         (reboot)\n";
            print STDERR "         wsl --update && wsl --set-default-version 2\n";
            print STDERR "\n";
            die_bootstrap("Hyper-V backend detected — see above. Sandbox refuses to bootstrap on this configuration.");
        }
    }
}

my $image_check = `$PODMAN image inspect claude-sandbox:latest 2>&1`;
if ($? == 0) {
    log_skip("claude-sandbox:latest already built");
} else {
    log_done("image missing — building (this can take a few minutes)");
    my $host_version = `claude --version 2>/dev/null`;
    chomp $host_version if defined $host_version;
    ($host_version) = split /\s+/, ($host_version // '');
    $host_version //= 'latest';
    my $rc = system($PODMAN, 'build',
        '--build-arg', "CLAUDE_VERSION=$host_version",
        '-t', "claude-sandbox:$host_version",
        '-t', 'claude-sandbox:latest',
        $CONTAINER_CONFIG);
    die_bootstrap("$RUNTIME_NAME build failed (exit @{[$rc >> 8]})") if $rc != 0;
    log_done("built claude-sandbox:$host_version + :latest");
}

# =====================================================================
# Step 3: create .claude-data/
# =====================================================================

log_step("Step 3/6: create .claude-data/");
my $claude_data = "$PROJECT_PATH/.claude-data";
if (-d $claude_data) {
    log_skip(".claude-data/ already exists");
} else {
    make_path($claude_data) or die_bootstrap("mkdir $claude_data: $!");
    log_done("created $claude_data");
}

# =====================================================================
# Step 4: update .gitignore
# =====================================================================

log_step("Step 4/6: update .gitignore");
my $gitignore = "$PROJECT_PATH/.gitignore";
my %existing;
if (-f $gitignore) {
    open my $fh, '<:raw', $gitignore;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s|^\s+||;
        $line =~ s|\s+$||;
        $existing{$line} = 1 if length $line;
    }
    close $fh;
}

my @needs = grep { !$existing{$_} } ('.claude-data', 'deploy_key');
if (@needs) {
    open my $fh, '>>:raw', $gitignore
        or die_bootstrap("cannot append to $gitignore: $!");
    # Add a leading newline if the existing file didn't end in one (best-effort).
    if (-s $gitignore) {
        seek $fh, -1, 2;  # SEEK_END - 1
        my $last;
        read $fh, $last, 1;
        print $fh "\n" if defined $last && $last ne "\n";
        seek $fh, 0, 2;  # back to end for the append
    }
    print $fh "# Added by claude-sandbox bootstrap\n";
    print $fh "$_\n" for @needs;
    close $fh;
    log_done("appended: " . join(', ', @needs));
} else {
    log_skip("all entries already present");
}

# =====================================================================
# Step 5: git auth setup
# =====================================================================

log_step("Step 5/6: git auth setup");
{
    my $pat_marker      = "$claude_data/git-askpass.sh";
    my $deploy_key_path = "$PROJECT_PATH/deploy_key";

    if (-f $pat_marker) {
        log_skip("PAT auth (git-askpass.sh) already configured");
    } elsif (-f $deploy_key_path) {
        log_skip("deploy key already present at $deploy_key_path");
        # Ensure the SSH command wrapper exists too.
        _ensure_ssh_command_wrapper($claude_data);
    } else {
        # Need to set up something. Determine remote first.
        chdir $PROJECT_PATH or die_bootstrap("chdir $PROJECT_PATH: $!");
        my $remote = `git remote get-url origin 2>/dev/null`;
        chomp $remote if defined $remote;
        $remote //= '';

        if (!length $remote) {
            log_warn("no git remote configured; skipping git auth (you can re-run this bootstrap or configure auth manually later)");
        } elsif ($remote =~ m{^https?://}i) {
            _setup_pat_auth($claude_data);
        } elsif ($remote =~ m{^(?:git\@|ssh://)}i || $remote =~ m{^[^/]+:[^/]}) {
            _setup_ssh_auth($claude_data, $deploy_key_path);
        } else {
            log_warn("unrecognized remote format '$remote' — skipping git auth");
        }
    }
}

sub _setup_pat_auth {
    my $claude_data = shift;
    # Check for a global PAT (ccpraxis convention).
    my $global_pat_path = "$CLAUDE_HOST_CONFIG/.claude-data/git-pat";
    my $pat;
    if (-f $global_pat_path) {
        open my $fh, '<:raw', $global_pat_path;
        local $/; $pat = <$fh>;
        close $fh;
        chomp $pat if defined $pat;
        log_done("using global PAT from $global_pat_path");
    } else {
        print "\n";
        print "Repo uses HTTPS. Sandbox containers need a GitHub fine-grained PAT to push/pull.\n";
        print "Create one at https://github.com/settings/tokens?type=beta with read/write for this repo.\n";
        $pat = prompt_line("Paste your PAT (or leave blank to skip)", 1);
        if (!defined $pat || !length $pat) {
            log_warn("no PAT provided — sandbox container won't be able to push/pull");
            return;
        }
    }
    # Write the PAT and the askpass wrapper.
    open my $fh, '>:raw', "$claude_data/git-pat"
        or die_bootstrap("cannot write git-pat: $!");
    print $fh $pat;
    close $fh;
    chmod 0600, "$claude_data/git-pat" or log_warn("chmod 0600 git-pat: $!");

    open my $sh, '>:raw', "$claude_data/git-askpass.sh"
        or die_bootstrap("cannot write git-askpass.sh: $!");
    print $sh "#!/bin/bash\ncat /root/.claude/git-pat\n";
    close $sh;
    chmod 0755, "$claude_data/git-askpass.sh" or log_warn("chmod 0755 git-askpass.sh: $!");
    log_done("wrote git-pat (0600) + git-askpass.sh (0755)");
}

sub _setup_ssh_auth {
    my ($claude_data, $deploy_key_path) = @_;
    print "\n";
    my $choice = prompt_choice(
        "Repo uses SSH. Pick how to handle the deploy key for the sandbox container:",
        "Generate a new ed25519 deploy key (you'll add the public key to the git host)",
        "Provide a path to an existing private key (will be copied to $deploy_key_path)",
        "Skip git auth (sandbox container won't push/pull)",
    );
    return unless defined $choice;
    if ($choice == 0) {
        my $rc = system('ssh-keygen', '-t', 'ed25519', '-f', $deploy_key_path,
                        '-N', '', '-C', 'claude-sandbox');
        if ($rc != 0) {
            log_error("ssh-keygen failed (exit @{[$rc >> 8]})");
            return;
        }
        chmod 0600, $deploy_key_path or log_warn("chmod 0600 deploy_key: $!");
        my $pub_path = "$deploy_key_path.pub";
        if (-f $pub_path) {
            open my $fh, '<:raw', $pub_path;
            local $/; my $pub = <$fh>;
            close $fh;
            chomp $pub if defined $pub;
            print "\n>>> Public key (add this to the git host as a deploy key):\n\n";
            print "$pub\n\n";
            print "    Press Enter once you've added it.";
            <STDIN>;
        }
        _ensure_ssh_command_wrapper($claude_data);
        log_done("generated ed25519 deploy key + ssh-command wrapper");
    } elsif ($choice == 1) {
        my $src = prompt_line("Path to existing private key");
        return unless defined $src && length $src;
        $src =~ s|^~|$HOME|;
        unless (-f $src) {
            log_error("$src not found");
            return;
        }
        # Copy bytes.
        open my $in,  '<:raw', $src             or die_bootstrap("read $src: $!");
        open my $out, '>:raw', $deploy_key_path or die_bootstrap("write $deploy_key_path: $!");
        local $/; print $out scalar <$in>;
        close $out; close $in;
        chmod 0600, $deploy_key_path or log_warn("chmod 0600 deploy_key: $!");
        _ensure_ssh_command_wrapper($claude_data);
        log_done("copied deploy key + ssh-command wrapper");
    } else {
        log_warn("git auth skipped");
    }
}

sub _ensure_ssh_command_wrapper {
    my $claude_data = shift;
    my $wrapper = "$claude_data/git-ssh-command.sh";
    return if -f $wrapper;
    open my $fh, '>:raw', $wrapper or die_bootstrap("cannot write $wrapper: $!");
    print $fh "#!/bin/bash\nexec ssh -i /project/deploy_key -o StrictHostKeyChecking=no \"\$\@\"\n";
    close $fh;
    chmod 0755, $wrapper or log_warn("chmod 0755 git-ssh-command.sh: $!");
}

# =====================================================================
# Step 6: wire claude-sandbox to PATH
# =====================================================================

log_step("Step 6/6: wire claude-sandbox into PATH");
if (-f $CCPRAXIS_INSTALL_PL) {
    # Plan first so the user sees what changes.
    print "    Preview:\n";
    my $rc1 = system($^X, $CCPRAXIS_INSTALL_PL, 'plan');
    if ($rc1 != 0) {
        log_warn("install hook plan returned non-zero (@{[$rc1 >> 8]}) — skipping apply");
    } else {
        if (prompt_yn("    Apply these PATH changes now?", 'y')) {
            my $rc2 = system($^X, $CCPRAXIS_INSTALL_PL, 'apply');
            if ($rc2 != 0) {
                log_warn("install hook apply returned non-zero (@{[$rc2 >> 8]})");
            } else {
                log_done("PATH wired (you may need to open a new terminal for it to take effect)");
            }
        } else {
            log_skip("user declined PATH changes — claude-sandbox may not be on PATH yet");
        }
    }
} else {
    log_warn("$CCPRAXIS_INSTALL_PL not found — skipping PATH wiring");
}

# =====================================================================
# Done
# =====================================================================

print "\n";
print "==============================================================\n";
print "  Bootstrap complete. Continuing into the sandbox now...\n";
print "==============================================================\n";
print "\n";
exit 0;
