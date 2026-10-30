#!/usr/bin/perl
# claude-binary-backup.pl — snapshot, list, restore, prune, verify, detect and
# install-command operations on the Claude Code binary.
#
# Purpose: give /update a deterministic safety net. Before any installer
# runs, snapshot the current binary; if the installer leaves a broken or
# unwanted binary in place, restore from a snapshot with a single command.
#
# All output is JSON on stdout EXCEPT the `help` subcommand, which prints
# plain-text usage. Errors go to stderr AND are reflected in the JSON
# ({"status":"error","error":"..."}). Exit codes:
#   0 = success
#   1 = soft failure (operation didn't run; e.g. snapshot of missing binary)
#   2 = hard failure (data-integrity risk; e.g. SHA mismatch, partial write)
#   3 = usage error
#
# Atomic semantics:
#   - All destructive ops happen via write-to-.tmp + rename
#   - Restore takes a "pre-restore" snapshot before touching the live binary
#   - SHA-256 verified before AND after every copy
#   - flock prevents the script from racing itself
#
# Self-contained: only Perl core modules.

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:flock O_WRONLY O_CREAT O_EXCL);
use File::Copy qw(copy);
use File::Path qw(make_path remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;
use Encode qw(decode);

# emit_json's structures mix char strings (source_path read from a manifest via
# decode_json) with raw UTF-8 byte strings (the snapshot dir `path` from catfile).
# Normalize byte strings up to chars before the ->utf8 encoder so each is encoded
# exactly once (else the byte path double-encodes "André" -> "AndrÃ©"). NOTE: the
# manifest-write paths are intentionally left alone — their data is all byte
# strings (%ENV/@ARGV) written via a ':raw' handle with a utf8-off encoder, which
# passes the bytes through unchanged (correct UTF-8 on disk).
sub _decode_strings_recursive {
    my $x = shift;
    if (ref $x eq 'HASH') {
        return { map { $_ => _decode_strings_recursive($x->{$_}) } keys %$x };
    } elsif (ref $x eq 'ARRAY') {
        return [ map { _decode_strings_recursive($_) } @$x ];
    } elsif (ref $x) {
        return $x;
    } elsif (defined $x && !utf8::is_utf8($x)) {
        return $x + 0 if $x =~ /^-?\d+$/;
        return $x + 0 if $x =~ /^-?\d+\.\d+$/;
        # FB_CROAK (not FB_QUIET): on invalid UTF-8, FB_QUIET returns the
        # successfully-decoded *prefix* (silently truncating CP1252 "Andr\xE9"
        # to "Andr"), making the fallback below dead code. Croak instead, then
        # fall back to a CP1252 decode — the from_fs() pattern from skills.pl.
        my $decoded = eval { decode('UTF-8', $x, Encode::FB_CROAK) };
        return defined $decoded ? $decoded : decode('cp1252', $x, Encode::FB_DEFAULT);
    }
    return $x;
}
use POSIX qw(strftime);

my $VERSION = '1.0.0';

# ─── Helpers ──────────────────────────────────────────────────────────────

sub home_dir {
    return $ENV{HOME} if defined $ENV{HOME} && length $ENV{HOME};
    return $ENV{USERPROFILE} if defined $ENV{USERPROFILE} && length $ENV{USERPROFILE};
    my $pw = eval { (getpwuid($<))[7] };
    return $pw if defined $pw;
    die "Cannot determine home directory (no HOME / USERPROFILE / pw entry)\n";
}

sub is_windows { return $^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys'; }

# True only on truly native Windows (no fork, no reliable alarm).
# Cygwin and msys have working POSIX primitives.
sub is_native_windows { return $^O eq 'MSWin32'; }

# Convert a path to Windows form. Identity on native Windows (already
# Windows-style). On cygwin/msys, converts /c/Users/... → C:\Users\....
sub to_windows_path {
    my ($p) = @_;
    return $p if $^O eq 'MSWin32';
    if ($^O eq 'cygwin' || $^O eq 'msys') {
        # Prefer cygpath if available (handles symlinks and mount table)
        my $w = `cygpath -w "$p" 2>/dev/null`;
        if (defined $w) {
            chomp $w;
            return $w if length $w;
        }
        # Manual fallback: /c/foo/bar → C:\foo\bar
        if ($p =~ m{^/([a-zA-Z])/(.*)$}) {
            my $drive = uc $1;
            my $rest  = $2;
            $rest =~ s{/}{\\}g;
            return "$drive:\\$rest";
        }
    }
    return $p;
}

sub backup_root {
    # Env override for testing — never document this in user-facing surfaces;
    # it's a test seam.
    if (defined $ENV{CLAUDE_BINARY_BACKUP_ROOT} && length $ENV{CLAUDE_BINARY_BACKUP_ROOT}) {
        return $ENV{CLAUDE_BINARY_BACKUP_ROOT};
    }
    return File::Spec->catdir(home_dir(), '.claude', 'backups', 'claude-code');
}

sub lock_path {
    return File::Spec->catfile(backup_root(), '.lock');
}

# Default binary path: the native install. install-command (below) tells a
# native install from an npm or Homebrew one; snapshot/restore target this
# path unless --binary says otherwise.
sub default_binary_path {
    my $home = home_dir();
    if (is_windows()) {
        return File::Spec->catfile($home, '.local', 'bin', 'claude.exe');
    }
    return File::Spec->catfile($home, '.local', 'bin', 'claude');
}

sub utc_timestamp {
    return strftime('%Y-%m-%dT%H%M%SZ', gmtime);
}

# File::Copy::copy creates its destination with the default 0666 & ~umask
# mode, so on Linux/macOS a copied executable comes out 0644. Harmless for a
# snapshot nobody runs, fatal for a restore: the restored `claude` would not be
# executable. Give $dst the permission bits of $mode_src. Windows has no mode
# bits worth carrying (and exec-ness is the .exe name), so it is left alone.
sub copy_mode {
    my ($mode_src, $dst) = @_;
    return 1 if is_windows();
    my @st = stat($mode_src);
    return 0 unless @st;
    return chmod($st[2] & 07777, $dst) ? 1 : 0;
}

# Mode for a restored binary when there is no live file to take it from: the
# snapshot's own bits, plus an exec bit wherever there is a read bit (a
# snapshot taken before copy_mode existed is 0644), and always owner-exec.
sub restore_mode_from_snapshot {
    my ($snap_bin) = @_;
    my @st = stat($snap_bin);
    my $m = @st ? ($st[2] & 07777) : 0644;
    return $m | (($m & 0444) >> 2) | 0100;
}

# The file a restore must write when $path is a symlink. On macOS (and the
# Linux native installer) ~/.local/bin/claude is a symlink into
# ~/.local/share/claude/versions/<v>; renaming a staged file over the link
# would replace the link itself with a plain file and orphan the layout the
# installer manages. Restore THROUGH it instead: follow the chain (relative
# targets resolve against the link's own directory) to the real file, which
# may not exist any more. Returns $path unchanged for a non-link or on Windows.
sub resolve_restore_target {
    my ($path) = @_;
    return $path if is_windows();
    my $p = $path;
    for (1 .. 40) {
        last unless -l $p;
        my $t = readlink($p);
        last unless defined $t && length $t;
        unless (File::Spec->file_name_is_absolute($t)) {
            my ($vol, $dir) = File::Spec->splitpath($p);
            $t = File::Spec->catpath($vol, $dir, $t);
        }
        $p = $t;
    }
    my ($vol, $dir, $file) = File::Spec->splitpath($p);
    my $real_dir = abs_path(File::Spec->catpath($vol, $dir, ''));
    return defined $real_dir ? File::Spec->catfile($real_dir, $file) : $p;
}

sub emit_json {
    my ($obj) = @_;
    # Normalize mixed char/byte strings up to chars, then ->utf8 emits UTF-8
    # bytes to byte-mode STDOUT — each string encoded exactly once.
    my $json = JSON::PP->new->utf8->canonical->pretty;
    print $json->encode(_decode_strings_recursive($obj));
}

sub die_json {
    my ($exit_code, $msg, %extra) = @_;
    my %obj = (status => 'error', error => $msg, %extra);
    emit_json(\%obj);
    exit $exit_code;
}

sub sha256_file {
    my ($path) = @_;
    open my $fh, '<', $path or return undef;
    binmode $fh;
    my $sha = Digest::SHA->new(256);
    $sha->addfile($fh);
    close $fh;
    return $sha->hexdigest;
}

sub file_size {
    my ($path) = @_;
    my @st = stat($path);
    return @st ? $st[7] : undef;
}

# Probe free disk bytes for a given directory. Best-effort; returns undef
# when we cannot determine it (do NOT block ops on undef — just skip the
# pre-flight check, the actual copy will fail later if disk is full).
sub free_bytes {
    my ($dir) = @_;
    return undef unless -d $dir;
    # Native Windows only — PowerShell Get-PSDrive
    if (is_native_windows()) {
        my $win_dir = to_windows_path($dir);
        my $drive = '';
        if ($win_dir =~ m{^([A-Za-z]):}) { $drive = uc $1; }
        return undef unless $drive;
        # NO SHELL-LEVEL stderr REDIRECT. This read `2>NUL`, and Git-for-Windows
        # perl runs backticks through sh -- where NUL is not a device but a
        # FILENAME, so every call left a literal `NUL` file in the working
        # directory that Explorer cannot delete. It is this repo's own
        # documented landmine, committed in this repo's own code; one was
        # created in /c/Development/ccpraxis on 2026-09-06 by the snapshot this
        # very script takes.
        #
        # `2>/dev/null` is NOT the fix either: it would be wrong the moment
        # backticks go through cmd.exe on a native-Windows perl. The suppression
        # belongs one layer in, where it is portable -- -ErrorAction
        # SilentlyContinue is already doing it, which is what made the redirect
        # redundant as well as harmful. Same reasoning as bp-keepawake.pl:229.
        my $out = `powershell -NoProfile -Command "(Get-PSDrive -Name $drive -ErrorAction SilentlyContinue).Free"`;
        return undef unless defined $out;
        chomp $out;
        $out =~ s/\s+//g;
        return undef unless $out =~ /^\d+$/;
        return 0 + $out;
    }
    # POSIX, cygwin, msys. -P asks for the POSIX format: one line per
    # filesystem, "Filesystem 1024-blocks Used Available Capacity Mounted on".
    # Without it macOS df adds iused/ifree/%iused columns, so the old
    # "third column from the end" read the free-INODE count as free bytes.
    # Matched by shape rather than by column index because both ends can hold
    # spaces: the mount point ("/Volumes/My Disk") and, on MSYS, the
    # filesystem ("C:/Program Files/Git").
    my $out = `df -kP "$dir" 2>/dev/null`;
    return undef unless $out;
    my @lines = split /\n/, $out;
    return undef unless @lines >= 2;
    my ($avail_k) = $lines[-1] =~ /\s(?:\d+)\s+(?:\d+)\s+(\d+)\s+\d+%\s/;
    return undef unless defined $avail_k;
    return $avail_k * 1024;
}

# Read binary version. Strategy:
#   1. On any Windows-flavoured runtime, query PowerShell for FileVersion.
#      On cygwin/msys, convert the path to Windows form first. PowerShell
#      works even when the binary itself is broken — important when
#      diagnosing a botched install.
#   2. If PowerShell didn't yield a version AND we have working POSIX
#      primitives (any POSIX, or cygwin/msys — NOT native MSWin32), exec
#      the binary with a 10s SIGALRM timeout. Native MSWin32 skips this
#      because its alarm is unreliable.
#   3. Otherwise return 'unknown' — never hang.
sub read_binary_version {
    my ($path) = @_;
    return 'unknown' unless -f $path;

    # 1. PowerShell path (Windows-flavoured runtimes).
    if (is_windows()) {
        my $win_path = to_windows_path($path);
        my $q = $win_path;
        $q =~ s/'/''/g;  # PowerShell single-quote escape
        # Same fix as free_bytes above: the `2>NUL` that used to end this line
        # created a literal NUL file under sh. Here the suppression was doing
        # real work -- a missing file makes Get-Item write an error -- so it
        # moves inside PowerShell as -ErrorAction SilentlyContinue rather than
        # being dropped. The caller already treats empty output as 'unknown'.
        my $cmd = "powershell -NoProfile -Command \"(Get-Item -LiteralPath '$q' -ErrorAction SilentlyContinue).VersionInfo.ProductVersion\"";
        my $out = `$cmd`;
        if (defined $out) {
            chomp $out;
            $out =~ s/\s+//g;
            if (length $out && $out =~ /^\d+(?:\.\d+)+/) {
                # Normalize trailing ".0" if present (e.g. 2.1.126.0 → 2.1.126)
                $out =~ s/\.0+$//;
                return $out;
            }
        }
        # On native Windows, do NOT fall through to exec — alarm is unreliable.
        return 'unknown' if is_native_windows();
    }

    # 2. POSIX exec path. Safe on POSIX and on cygwin/msys (working fork +
    # alarm). List-form open avoids shell interpolation.
    my $version = 'unknown';
    my $out = '';
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 10;
        my $pid = open(my $fh, '-|');
        if (!defined $pid) {
            die "fork failed: $!\n";
        }
        if ($pid == 0) {
            # Child: redirect stderr → stdout, exec the binary
            open(STDERR, '>&', \*STDOUT);
            exec { $path } $path, '--version'
                or do { print STDERR "exec failed: $!\n"; exit 127; };
        }
        local $/;
        $out = <$fh> // '';
        close $fh;
        alarm 0;
    };
    alarm 0;
    if (defined $out && $out =~ /(\d+\.\d+\.\d+(?:\.\d+)?)/) {
        $version = $1;
        $version =~ s/\.0+$//;
    }
    return $version;
}

# Acquire an exclusive lock on .lock under backup_root. Returns the open
# filehandle (caller releases by closing/letting it go out of scope).
sub acquire_lock {
    my $root = backup_root();
    make_path($root) unless -d $root;
    my $lp = lock_path();
    open my $lfh, '>>', $lp or die "Cannot open lock file $lp: $!\n";
    flock($lfh, LOCK_EX) or die "Cannot acquire lock on $lp: $!\n";
    return $lfh;
}

# Sweep `.tmp` debris left by killed prior invocations. Safe because
# the rename to the final name is atomic — `.tmp` only exists if a
# prior op was interrupted.
sub sweep_tmp {
    my $root = backup_root();
    return unless -d $root;
    opendir my $dh, $root or return;
    while (defined(my $e = readdir $dh)) {
        next if $e eq '.' || $e eq '..';
        next unless $e =~ /\.tmp$/;
        my $p = File::Spec->catdir($root, $e);
        next unless -d $p;
        remove_tree($p);
    }
    closedir $dh;
}

# Read manifest for a given snapshot directory; returns hashref or undef
# if missing/corrupt.
sub read_manifest {
    my ($snap_dir) = @_;
    my $mp = File::Spec->catfile($snap_dir, 'manifest.json');
    return undef unless -f $mp;
    open my $fh, '<', $mp or return undef;
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $obj = eval { decode_json($raw) };
    return undef if $@ || ref($obj) ne 'HASH';
    return $obj;
}

# List snapshot dirs sorted newest-first. Returns list of hashrefs:
#   { id => "...", path => "/abs/path", manifest => {...} or undef, corrupt => bool }
sub enumerate_snapshots {
    my $root = backup_root();
    return () unless -d $root;
    opendir my $dh, $root or return ();
    my @entries;
    while (defined(my $e = readdir $dh)) {
        next if $e eq '.' || $e eq '..' || $e eq '.lock';
        next if $e =~ /\.tmp$/;
        my $p = File::Spec->catdir($root, $e);
        next unless -d $p;
        my $m = read_manifest($p);
        push @entries, {
            id       => $e,
            path     => $p,
            manifest => $m,
            corrupt  => (!defined $m) ? 1 : 0,
        };
    }
    closedir $dh;
    # Sort by manifest captured_at_utc (descending); corrupt entries last.
    @entries = sort {
        my $ta = ($a->{manifest} // {})->{captured_at_utc} // '';
        my $tb = ($b->{manifest} // {})->{captured_at_utc} // '';
        if ($ta eq '' && $tb eq '') {
            # Fall back to id (which has leading timestamp) descending
            return $b->{id} cmp $a->{id};
        }
        return $tb cmp $ta;
    } @entries;
    return @entries;
}

# ─── Subcommands ──────────────────────────────────────────────────────────

sub cmd_detect {
    my (@args) = @_;
    my $binary;
    GetOptionsFromArray(\@args, 'binary=s' => \$binary)
        or die_json(3, 'Usage: detect [--binary <path>]');
    $binary //= default_binary_path();
    my $exists = -f $binary;
    my %r = (
        status      => ($exists ? 'ok' : 'missing'),
        binary_path => $binary,
        exists      => ($exists ? JSON::PP::true : JSON::PP::false),
        os          => $^O,
    );
    if ($exists) {
        $r{size}    = file_size($binary);
        $r{version} = read_binary_version($binary);
        $r{sha256}  = sha256_file($binary);
    }
    emit_json(\%r);
    exit($exists ? 0 : 1);
}

# ─── install-command ──────────────────────────────────────────────────────
#
# /steward:update installs the version the user chose, and the command that
# does it depends on how Claude Code was installed and on the OS. The skill
# used to list every OS's installer command and ask the agent to pick the
# matching line; the pick is made here instead, from the claude actually on
# PATH, and the skill runs the one command this prints.

# The OS the installer command is chosen for. CLAUDE_BINARY_OS is a test seam
# (windows | macos | linux), like CLAUDE_BINARY_BACKUP_ROOT -- never document
# it in user-facing surfaces.
sub install_os {
    my $o = $ENV{CLAUDE_BINARY_OS};
    return $o if defined $o && $o =~ /\A(?:windows|macos|linux)\z/;
    return 'windows' if is_windows();
    return $^O eq 'darwin' ? 'macos' : 'linux';
}

# One spelling of a path for comparison: forward slashes, an MSYS /c/... as
# c:/..., no trailing slash, and lower case on the case-insensitive
# filesystems (Windows, APFS).
sub _cmp_path {
    my ($p, $os) = @_;
    return '' unless defined $p && length $p;
    $p =~ s{\\}{/}g;
    $p =~ s{\A/([A-Za-z])(?=/|\z)}{$1:};
    $p =~ s{/+\z}{} unless $p eq '/';
    return ($os eq 'windows' || $os eq 'macos') ? lc $p : $p;
}

# find_claude_on_path($os) -> the first claude on PATH, or undef.
sub find_claude_on_path {
    my ($os) = @_;
    require Config;
    my $sep = $Config::Config{path_sep} || ':';
    my @names = $os eq 'windows' ? ('claude.exe', 'claude.cmd', 'claude') : ('claude');
    for my $dir (split /\Q$sep\E/, (defined $ENV{PATH} ? $ENV{PATH} : '')) {
        next unless length $dir;
        for my $n (@names) {
            my $p = File::Spec->catfile($dir, $n);
            return $p if -f $p && ($os eq 'windows' || -x $p);
        }
    }
    return undef;
}

# classify_install(path => $found, resolved => $realpath, home => $home,
#                  os => $os) -> 'npm' | 'brew' | 'native' | 'unknown'
# npm first: an npm prefix of ~/.local puts its shim at ~/.local/bin/claude,
# which would otherwise read as native.
sub classify_install {
    my (%a) = @_;
    my $os   = $a{os};
    my $path = _cmp_path($a{path}, $os);
    my $real = _cmp_path($a{resolved}, $os);
    my $home = _cmp_path($a{home}, $os);
    my @both = grep { length } ($path, $real);
    return 'unknown' unless @both;

    return 'npm' if grep { m{/node_modules/} } @both;
    if (defined $a{path} && $a{path} =~ /\.(?:cmd|ps1)\z/i) {
        my $dir = $a{path};
        $dir =~ s{[\\/][^\\/]+\z}{};
        return 'npm' if -d File::Spec->catdir($dir, 'node_modules', '@anthropic-ai', 'claude-code');
    }
    return 'brew' if grep { m{/(?:caskroom|cellar)/}i } @both;
    return 'brew' if $path =~ m{\A(?:/opt/homebrew|/home/linuxbrew/\.linuxbrew)/};
    if (length $home) {
        return 'native' if $path eq "$home/.local/bin/claude" || $path eq "$home/.local/bin/claude.exe";
        # The resolved path is canonical (on macOS, /var/... comes back as
        # /private/var/...), so compare it with the canonical home as well.
        my $home_real = (defined $a{home} && -d $a{home}) ? _cmp_path(abs_path($a{home}), $os) : '';
        for my $h (grep { length } ($home, $home_real)) {
            return 'native' if index($real, "$h/.local/share/claude/") == 0;
        }
    }
    return 'unknown';
}

# install_command($method, $version, $os) -> ($command | undef, $note)
sub install_command {
    my ($method, $v, $os) = @_;
    if ($method eq 'native') {
        return ($os eq 'windows'
            ? qq{powershell -Command "& ([scriptblock]::Create((irm https://claude.ai/install.ps1))) $v"}
            : "curl -fsSL https://claude.ai/install.sh | bash -s $v",
            "native install: the official installer, pinned to $v");
    }
    if ($method eq 'npm') {
        return ("npm install -g \@anthropic-ai/claude-code\@$v", "npm global install, pinned to $v");
    }
    if ($method eq 'brew') {
        return (undef, "Homebrew install: Homebrew installs only the version its own formula currently ships, so $v cannot be pinned. Tell the user, and run nothing unless they choose Homebrew's version or another install method.");
    }
    return (undef, 'could not tell how Claude Code was installed from the claude found on PATH (see binary_path). Ask the user how it was installed before running anything.');
}

sub cmd_install_command {
    my (@args) = @_;
    my ($version, $binary);
    GetOptionsFromArray(\@args, 'version=s' => \$version, 'binary=s' => \$binary)
        or die_json(3, 'Usage: install-command --version <x.y.z> [--binary <path>]');
    die_json(3, 'install-command needs --version <x.y.z>') unless defined $version;
    # The version lands in a shell command line, so only a version shape gets
    # through: digits and dots, an optional pre-release tag of [0-9A-Za-z.-].
    die_json(3, "not a version: '$version'")
        unless $version =~ /\A\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/;

    my $os    = install_os();
    my $found = defined $binary ? $binary : find_claude_on_path($os);
    my $real  = (defined $found && -e $found) ? (abs_path($found) // $found) : undef;
    my $method = defined $found
        ? classify_install(path => $found, resolved => $real, home => home_dir(), os => $os)
        : 'unknown';
    my ($command, $note) = install_command($method, $version, $os);
    $note = 'no claude found on PATH. Ask the user how Claude Code was installed before running anything.'
        unless defined $found;
    emit_json({
        status        => (defined $command ? 'ok' : 'no-command'),
        os            => $os,
        method        => $method,
        binary_path   => $found,
        resolved_path => $real,
        version       => $version,
        command       => $command,
        note          => $note,
    });
    exit(defined $command ? 0 : 1);
}

sub cmd_snapshot {
    my (@args) = @_;
    my ($binary, $reason, $mark);
    GetOptionsFromArray(\@args,
        'binary=s' => \$binary,
        'reason=s' => \$reason,    # optional label written to manifest
        'mark=s'   => \$mark,      # optional categorical mark (e.g. 'pre-restore', 'pre-install')
    ) or die_json(3, 'Usage: snapshot [--binary <path>] [--reason <text>] [--mark <label>]');

    $binary //= default_binary_path();
    die_json(1, "Source binary not found: $binary",
              binary_path => $binary)
        unless -f $binary;

    my $size    = file_size($binary);
    die_json(2, "Cannot stat source binary: $binary") unless defined $size;

    my $src_sha = sha256_file($binary);
    die_json(2, "Cannot read source binary for SHA: $binary") unless defined $src_sha;

    my $version = read_binary_version($binary);
    my $ts      = utc_timestamp();
    my $safe_ver = $version;
    $safe_ver =~ s/[^A-Za-z0-9._-]/_/g;
    my $id      = "${ts}__v${safe_ver}";
    $id .= "__${mark}" if defined $mark && length $mark;

    my $root  = backup_root();
    my $lfh   = acquire_lock();
    sweep_tmp();

    my $final = File::Spec->catdir($root, $id);
    my $tmp   = "${final}.tmp";

    # Refuse to overwrite an existing snapshot of the same id
    if (-d $final) {
        die_json(1, "Snapshot already exists: $id", id => $id);
    }

    # Disk-space pre-flight (advisory)
    my $free = free_bytes($root);
    if (defined $free && $free < $size * 2) {
        die_json(2, "Insufficient free space (need ~" . ($size * 2) . " bytes, have $free)",
                  free_bytes => $free, required_bytes => $size * 2);
    }

    # make_path can die on error and returns the list of created dirs
    # (empty if target already exists). Use eval + existence check.
    eval { make_path($tmp) };
    unless (-d $tmp) {
        my $why = $@ || $! || 'unknown';
        die_json(2, "Cannot create temp snapshot dir: $tmp ($why)");
    }

    my $bin_name = is_windows() ? 'claude.exe' : 'claude';
    my $tmp_bin  = File::Spec->catfile($tmp, $bin_name);

    unless (copy($binary, $tmp_bin)) {
        my $err = $!;
        remove_tree($tmp);
        die_json(2, "Copy failed: $err");
    }
    unless (copy_mode($binary, $tmp_bin)) {
        my $err = $!;
        remove_tree($tmp);
        die_json(2, "Cannot carry the binary's mode onto the snapshot: $err");
    }

    # Post-copy verification: re-hash the destination
    my $dst_sha = sha256_file($tmp_bin);
    unless (defined $dst_sha && $dst_sha eq $src_sha) {
        remove_tree($tmp);
        die_json(2, "SHA mismatch after copy (source=$src_sha, dest=" . ($dst_sha // 'undef') . ")");
    }

    my $dst_size = file_size($tmp_bin);
    unless (defined $dst_size && $dst_size == $size) {
        remove_tree($tmp);
        die_json(2, "Size mismatch after copy (source=$size, dest=" . ($dst_size // 'undef') . ")");
    }

    my %manifest = (
        manifest_version => 1,
        id               => $id,
        version          => $version,
        source_path      => $binary,
        sha256           => $src_sha,
        size             => $size,
        os               => $^O,
        captured_at_utc  => $ts,
        binary_filename  => $bin_name,
    );
    $manifest{reason} = $reason if defined $reason;
    $manifest{mark}   = $mark   if defined $mark;

    my $mp = File::Spec->catfile($tmp, 'manifest.json');
    open my $mfh, '>', $mp or do {
        remove_tree($tmp);
        die_json(2, "Cannot write manifest: $mp ($!)");
    };
    # JSON::PP->encode already produces UTF-8 byte strings. Use :raw to
    # avoid double-encoding command-line args (which arrive as raw UTF-8
    # bytes from the OS) when they contain non-ASCII characters.
    binmode $mfh, ':raw';
    my $json = JSON::PP->new->canonical->pretty;
    print $mfh $json->encode(\%manifest);
    close $mfh;

    # Atomic-ish rename. Cross-platform note: rename of a directory is
    # atomic on POSIX. On Windows, rename of a directory across the same
    # volume is atomic in practice. We do not support cross-volume
    # snapshot roots — backups live under $HOME.
    unless (rename($tmp, $final)) {
        my $err = $!;
        remove_tree($tmp);
        die_json(2, "Atomic rename failed: $err");
    }

    close $lfh;

    emit_json({
        status   => 'snapshot_created',
        id       => $id,
        path     => $final,
        manifest => \%manifest,
    });
    exit 0;
}

sub cmd_list {
    my (@args) = @_;
    GetOptionsFromArray(\@args)
        or die_json(3, 'Usage: list');
    my $lfh = acquire_lock();
    sweep_tmp();
    my @snaps = enumerate_snapshots();
    close $lfh;

    my @out = map {
        +{
            id              => $_->{id},
            path            => $_->{path},
            corrupt         => $_->{corrupt} ? JSON::PP::true : JSON::PP::false,
            manifest        => $_->{manifest},
        }
    } @snaps;
    emit_json({ status => 'ok', count => scalar(@out), snapshots => \@out });
    exit 0;
}

# Locate a snapshot by id or "--latest". Returns ($entry, $err).
# For "--latest", skips entries whose binary fails integrity verification —
# not just manifest corruption. This makes restore --latest robust to
# half-broken snapshots and prevents the user from being stuck on a
# bad-binary entry when older healthy snapshots exist.
sub find_snapshot {
    my (%args) = @_;
    my @snaps = enumerate_snapshots();
    return (undef, 'No snapshots available') unless @snaps;
    if ($args{latest}) {
        my @rejected;
        for my $s (@snaps) {
            if ($s->{corrupt}) {
                push @rejected, { id => $s->{id}, reason => 'manifest corrupt' };
                next;
            }
            my ($ok, $details) = verify_snapshot($s);
            if ($ok) { return ($s, undef); }
            push @rejected, {
                id     => $s->{id},
                reason => $details->{error} // 'integrity failure',
            };
        }
        my $detail = join(', ', map { "$_->{id} ($_->{reason})" } @rejected);
        return (undef, "No healthy snapshots available (all fail integrity check). Rejected: $detail");
    }
    if (defined $args{id} && length $args{id}) {
        for my $s (@snaps) {
            return ($s, undef) if $s->{id} eq $args{id};
        }
        return (undef, "Snapshot not found: $args{id}");
    }
    return (undef, 'Specify --snapshot <id> or --latest');
}

# Verify a snapshot's binary against its manifest SHA. Returns
# ($ok_bool, $details_hashref).
sub verify_snapshot {
    my ($entry) = @_;
    return (0, { error => 'manifest missing or corrupt' }) if $entry->{corrupt};
    my $m = $entry->{manifest};
    my $bin = File::Spec->catfile($entry->{path}, $m->{binary_filename} // 'claude');
    return (0, { error => "binary missing: $bin" }) unless -f $bin;
    my $actual = sha256_file($bin);
    return (0, { error => "cannot hash binary: $bin" }) unless defined $actual;
    my $expected = $m->{sha256} // '';
    return (0, {
        error    => 'SHA mismatch',
        expected => $expected,
        actual   => $actual,
    }) unless $expected eq $actual;
    my $size = file_size($bin);
    my $expected_size = $m->{size} // -1;
    return (0, {
        error    => 'size mismatch',
        expected => $expected_size,
        actual   => $size,
    }) unless defined $size && $size == $expected_size;
    return (1, { sha256 => $actual, size => $size });
}

sub cmd_verify {
    my (@args) = @_;
    my ($id, $latest);
    GetOptionsFromArray(\@args,
        'snapshot=s' => \$id,
        'latest'     => \$latest,
    ) or die_json(3, 'Usage: verify --snapshot <id> | --latest');

    # Validate flag combination explicitly (usage error → exit 3)
    if ($latest && defined $id && length $id) {
        die_json(3, '--latest and --snapshot are mutually exclusive');
    }
    if (!$latest && !(defined $id && length $id)) {
        die_json(3, 'Specify --snapshot <id> or --latest');
    }

    my $lfh = acquire_lock();
    sweep_tmp();
    my ($entry, $err) = find_snapshot(id => $id, latest => $latest);
    close $lfh;
    die_json(1, $err) if $err;

    my ($ok, $details) = verify_snapshot($entry);
    if ($ok) {
        emit_json({
            status   => 'ok',
            id       => $entry->{id},
            sha256   => $details->{sha256},
            size     => $details->{size},
            manifest => $entry->{manifest},
        });
        exit 0;
    }
    die_json(2, "Snapshot verification failed: " . ($details->{error} // 'unknown'),
              id => $entry->{id}, details => $details);
}

sub cmd_restore {
    my (@args) = @_;
    my ($id, $latest, $binary, $no_pre_snapshot, $dry_run);
    GetOptionsFromArray(\@args,
        'snapshot=s'      => \$id,
        'latest'          => \$latest,
        'binary=s'        => \$binary,
        'no-pre-snapshot' => \$no_pre_snapshot,
        'dry-run'         => \$dry_run,
    ) or die_json(3, 'Usage: restore [--snapshot <id> | --latest] [--binary <path>] [--no-pre-snapshot] [--dry-run]');

    $binary //= default_binary_path();

    # Validate flag combination explicitly (usage error → exit 3)
    if ($latest && defined $id && length $id) {
        die_json(3, '--latest and --snapshot are mutually exclusive');
    }
    if (!$latest && !(defined $id && length $id)) {
        die_json(3, 'Specify --snapshot <id> or --latest');
    }

    my $lfh = acquire_lock();
    sweep_tmp();
    my ($entry, $err) = find_snapshot(id => $id, latest => $latest);
    if ($err) { close $lfh; die_json(1, $err); }

    # ALWAYS verify the snapshot BEFORE touching the live binary.
    my ($ok, $details) = verify_snapshot($entry);
    unless ($ok) {
        close $lfh;
        die_json(2, "Refusing to restore from corrupt snapshot: " . ($details->{error} // 'unknown'),
                  id => $entry->{id}, details => $details);
    }

    my $m = $entry->{manifest};
    my $snap_bin = File::Spec->catfile($entry->{path}, $m->{binary_filename} // 'claude');

    if ($dry_run) {
        close $lfh;
        emit_json({
            status      => 'dry_run',
            would_restore_from => $entry->{id},
            target_binary => $binary,
            target_exists => (-f $binary ? JSON::PP::true : JSON::PP::false),
            manifest    => $m,
        });
        exit 0;
    }

    # Take a pre-restore snapshot of the live binary unless suppressed
    # or the live binary doesn't exist.
    my $pre_snapshot_id;
    if (!$no_pre_snapshot && -f $binary) {
        # Capture inline (we already hold the lock; reuse the snapshot code
        # path by calling cmd_snapshot would re-lock — so duplicate logic
        # here, carefully). Same integrity guards as cmd_snapshot.
        my $src_sha = sha256_file($binary);
        unless (defined $src_sha) {
            close $lfh;
            die_json(2, "Cannot read pre-restore source binary for SHA: $binary");
        }
        my $size = file_size($binary);
        unless (defined $size) {
            close $lfh;
            die_json(2, "Cannot stat pre-restore source binary: $binary");
        }
        my $version = read_binary_version($binary);
        my $ts      = utc_timestamp();
        my $safe_ver = $version;
        $safe_ver =~ s/[^A-Za-z0-9._-]/_/g;
        my $pid     = "${ts}__v${safe_ver}__pre-restore";
        my $root    = backup_root();
        my $final   = File::Spec->catdir($root, $pid);
        my $tmp     = "${final}.tmp";

        if (-d $final) {
            close $lfh;
            die_json(2, "Pre-restore snapshot id collision: $pid");
        }
        eval { make_path($tmp) };
        unless (-d $tmp) {
            my $why = $@ || $! || 'unknown';
            close $lfh;
            die_json(2, "Cannot create pre-restore tmp dir: $tmp ($why)");
        }

        my $bin_name = is_windows() ? 'claude.exe' : 'claude';
        my $tmp_bin  = File::Spec->catfile($tmp, $bin_name);
        unless (copy($binary, $tmp_bin)) {
            my $e = $!;
            remove_tree($tmp);
            close $lfh;
            die_json(2, "Pre-restore copy failed: $e");
        }
        unless (copy_mode($binary, $tmp_bin)) {
            my $e = $!;
            remove_tree($tmp);
            close $lfh;
            die_json(2, "Pre-restore copy could not take the binary's mode: $e");
        }
        my $dst_sha = sha256_file($tmp_bin);
        unless (defined $dst_sha && $dst_sha eq $src_sha) {
            remove_tree($tmp);
            close $lfh;
            die_json(2, "Pre-restore SHA mismatch");
        }
        my %manifest = (
            manifest_version => 1,
            id               => $pid,
            version          => $version,
            source_path      => $binary,
            sha256           => $src_sha,
            size             => $size,
            os               => $^O,
            captured_at_utc  => $ts,
            binary_filename  => $bin_name,
            mark             => 'pre-restore',
            reason           => "auto-snapshot before restoring $entry->{id}",
        );
        my $mp = File::Spec->catfile($tmp, 'manifest.json');
        open my $mfh, '>', $mp or do {
            remove_tree($tmp);
            close $lfh;
            die_json(2, "Cannot write pre-restore manifest: $mp ($!)");
        };
        binmode $mfh, ':raw';  # JSON::PP encode already returns UTF-8 bytes
        print $mfh JSON::PP->new->canonical->pretty->encode(\%manifest);
        close $mfh;
        unless (rename($tmp, $final)) {
            my $e = $!;
            remove_tree($tmp);
            close $lfh;
            die_json(2, "Pre-restore rename failed: $e");
        }
        $pre_snapshot_id = $pid;
    }

    # Copy snapshot binary to a .tmp next to the live binary, verify,
    # then atomic rename. When $binary is a symlink (~/.local/bin/claude on
    # macOS points into ~/.local/share/claude/versions/), the file written is
    # the link's target and the link itself is left in place -- see
    # resolve_restore_target.
    my $target = resolve_restore_target($binary);
    my ($vol, $dir, undef) = File::Spec->splitpath($target);
    my $tgt_dir = File::Spec->catpath($vol, $dir, '');
    unless (-d $tgt_dir) {
        close $lfh;
        die_json(2, "Target binary dir does not exist: $tgt_dir");
    }

    my $stage = $target . '.restore.tmp';
    # Clean up any leftover .restore.tmp from a prior killed restore
    if (-e $stage) { unlink $stage; }

    unless (copy($snap_bin, $stage)) {
        my $e = $!;
        unlink $stage if -e $stage;
        close $lfh;
        die_json(2, "Restore copy to staging failed: $e",
                  pre_restore_snapshot => $pre_snapshot_id);
    }

    # The live binary keeps the mode it had; a binary that is gone gets the
    # snapshot's, made executable (restore_mode_from_snapshot). Without this
    # the staged copy is 0644 and the restored claude cannot be run.
    unless (is_windows()) {
        my $mode = (-f $target) ? ((stat($target))[2] & 07777) : restore_mode_from_snapshot($snap_bin);
        unless (chmod($mode, $stage)) {
            my $e = $!;
            unlink $stage if -e $stage;
            close $lfh;
            die_json(2, "Cannot set the restored binary's mode: $e",
                      pre_restore_snapshot => $pre_snapshot_id);
        }
    }

    my $stage_sha = sha256_file($stage);
    unless (defined $stage_sha && $stage_sha eq $m->{sha256}) {
        unlink $stage if -e $stage;
        close $lfh;
        die_json(2, "Staged file SHA mismatch — refusing to swap",
                  expected => $m->{sha256},
                  actual   => $stage_sha,
                  pre_restore_snapshot => $pre_snapshot_id);
    }

    # On Windows, an in-use exe cannot be renamed-over. Detect and
    # surface a clear error rather than a cryptic OS code.
    if (is_windows() && -f $binary) {
        # Probe by trying to open for write briefly. If denied, the
        # binary is in use.
        my $ok_open = sysopen(my $probe, $binary, O_WRONLY);
        if ($ok_open) { close $probe; }
        else {
            my $e = $!;
            # Allow proceeding; some Windows file-system behaviors return
            # the same EACCES even when rename will work. But warn.
            # We don't abort here — atomic rename can still succeed on
            # NTFS even if open-for-write is denied. The actual rename
            # is the ground truth.
        }
    }

    unless (rename($stage, $target)) {
        my $e = $!;
        unlink $stage if -e $stage;
        close $lfh;
        die_json(2, "Atomic rename over live binary failed: $e (likely in use)",
                  pre_restore_snapshot => $pre_snapshot_id);
    }

    # Final verification: live binary should now match the manifest SHA.
    my $live_sha = sha256_file($target);
    unless (defined $live_sha && $live_sha eq $m->{sha256}) {
        close $lfh;
        die_json(2, "Post-restore SHA mismatch — live binary may be corrupted",
                  expected => $m->{sha256},
                  actual   => $live_sha,
                  pre_restore_snapshot => $pre_snapshot_id);
    }

    close $lfh;
    emit_json({
        status                 => 'restored',
        restored_from          => $entry->{id},
        target_binary          => $binary,
        restored_path          => $target,
        sha256                 => $live_sha,
        pre_restore_snapshot   => $pre_snapshot_id,
        manifest               => $m,
    });
    exit 0;
}

sub cmd_prune {
    my (@args) = @_;
    my $keep = 4;
    my $dry_run;
    GetOptionsFromArray(\@args,
        'keep=i'  => \$keep,
        'dry-run' => \$dry_run,
    ) or die_json(3, 'Usage: prune [--keep N] [--dry-run]');

    die_json(3, '--keep must be >= 1') if $keep < 1;

    my $lfh = acquire_lock();
    sweep_tmp();

    # Sort newest-first; everything from index $keep onward gets removed.
    # Corrupt entries are removed PROVIDED we'd still have at least one
    # snapshot left after the prune. Never leave the user with zero
    # snapshots — even a corrupt one is better than nothing, since the
    # binary file inside may still be intact and the user can recover
    # manually.
    my @snaps = enumerate_snapshots();
    my (@kept, @to_remove);
    for my $i (0 .. $#snaps) {
        if ($snaps[$i]->{corrupt}) {
            push @to_remove, $snaps[$i];
        } elsif (scalar(@kept) < $keep) {
            push @kept, $snaps[$i];
        } else {
            push @to_remove, $snaps[$i];
        }
    }
    # Safety: if pruning would leave zero snapshots total, refuse to
    # delete the most-recent entry (corrupt or not). Put it back into @kept.
    my $would_be_zero = (scalar(@kept) == 0 && scalar(@to_remove) > 0);
    my @refused_for_safety;
    if ($would_be_zero) {
        my $rescue = shift @to_remove;  # most recent of the to-remove pool
        push @kept, $rescue;
        push @refused_for_safety, $rescue->{id};
    }

    my @removed_ids;
    my @failed;
    if (!$dry_run) {
        for my $s (@to_remove) {
            if (remove_tree($s->{path}, { safe => 1, error => \my $errs })) {
                push @removed_ids, $s->{id};
            } else {
                push @failed, { id => $s->{id}, error => join('; ', map { join(': ', %$_) } @{ $errs // [] }) };
            }
        }
    }
    close $lfh;

    emit_json({
        status              => $dry_run ? 'dry_run' : 'pruned',
        kept_count          => scalar(@kept),
        kept_ids            => [ map { $_->{id} } @kept ],
        removed_ids         => \@removed_ids,
        would_remove        => [ map { $_->{id} } @to_remove ],
        refused_for_safety  => \@refused_for_safety,
        failed              => \@failed,
        keep_setting        => $keep,
    });
    exit(scalar(@failed) ? 2 : 0);
}

sub cmd_help {
    print <<"EOF";
claude-binary-backup.pl v$VERSION

Subcommands:
  detect     [--binary <path>]
             Report whether the binary exists, its version, size, and SHA.

  install-command --version <x.y.z> [--binary <path>]
             Work out how the claude on PATH (or --binary) was installed and print the
             one command that installs version x.y.z on this machine. Exit 1 when there
             is no such command (a Homebrew install, or an unknown method); see "note".

  snapshot   [--binary <path>] [--reason <text>] [--mark <label>]
             Capture the current binary into a new versioned snapshot.

  list       List all snapshots as JSON (newest first).

  verify     --snapshot <id> | --latest
             Re-hash a snapshot's binary and compare against its manifest.

  restore    [--snapshot <id> | --latest] [--binary <path>]
             [--no-pre-snapshot] [--dry-run]
             Overwrite the live binary with the chosen snapshot. Takes a pre-restore snapshot first unless --no-pre-snapshot.

  prune      [--keep N] [--dry-run]
             Keep the N newest non-corrupt snapshots; remove the rest (always removes corrupt entries). Default N=4.

  help       Show this message.

Exit codes: 0=ok, 1=soft fail, 2=hard fail (integrity), 3=usage error.

All non-help output is JSON on stdout (this help screen is plain text).
EOF
    exit 0;
}

# ─── Dispatch ─────────────────────────────────────────────────────────────

my $sub = shift @ARGV;
$sub //= 'help';

if    ($sub eq 'detect')   { cmd_detect(@ARGV); }
elsif ($sub eq "install-command") { cmd_install_command(@ARGV); }
elsif ($sub eq 'snapshot') { cmd_snapshot(@ARGV); }
elsif ($sub eq 'list')     { cmd_list(@ARGV); }
elsif ($sub eq 'verify')   { cmd_verify(@ARGV); }
elsif ($sub eq 'restore')  { cmd_restore(@ARGV); }
elsif ($sub eq 'prune')    { cmd_prune(@ARGV); }
elsif ($sub eq 'help' || $sub eq '--help' || $sub eq '-h') { cmd_help(); }
else {
    die_json(3, "Unknown subcommand: $sub. Run 'help' for usage.");
}
