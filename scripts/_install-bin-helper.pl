#!/usr/bin/env perl
# _install-bin-helper.pl — shared logic for adding a bin/ dir to the user's
# PATH (and ensuring .PS1 in PATHEXT on Windows). Invoked by per-surface
# `ccpraxis-install.pl` hooks. Idempotent.
#
# Two modes:
#   perl _install-bin-helper.pl plan  <abs-bindir>    # describe what would change
#   perl _install-bin-helper.pl apply <abs-bindir>    # make the changes
#
# Linux/macOS: chmod +x the .sh launchers in <bindir>, create extensionless
# symlinks for any *.sh (so `claude-foo` works the same as `claude-foo.sh`),
# and append `export PATH=...` to the user's shell rc.
#
# Windows: read/write User-scope PATH and PATHEXT via powershell.exe.
# Values are passed base64-encoded to avoid any quoting concerns. Only the
# User scope is touched — no admin required.

use strict;
use warnings;
use File::Basename qw(basename);
use File::Glob qw(bsd_glob);
# No `use utf8;` — literal bytes flow straight to a :raw stdout (and
# we don't have Unicode literals in this file anyway).
use MIME::Base64 qw(encode_base64);
use POSIX qw(strftime);

# Use raw byte mode for stdout — we deal in UTF-8 byte strings from $Bin
# (Git Bash) and from base64-decoded PowerShell output; a :utf8 layer would
# double-encode them on display. Modern Git Bash + Windows Terminal default
# to UTF-8 consoles, so raw bytes render correctly.
binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $mode   = shift @ARGV // '';
my $bindir = shift @ARGV // '';

unless ($mode =~ /^(plan|apply)$/) {
    die "usage: $0 <plan|apply> <abs-bindir>\n";
}
die "ERROR: bindir not supplied\n" unless length $bindir;
die "ERROR: $bindir does not exist\n" unless -d $bindir;

# `$^O eq 'MSWin32'` only matches Strawberry/ActivePerl on Windows. Git
# Bash's bundled perl reports 'cygwin' (and some MSYS configs report 'msys')
# even though the user IS on a Windows host and wants registry edits for
# their User PATH. Treat all three as Windows.
if ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') {
    run_windows($mode, $bindir);
} else {
    run_unix($mode, $bindir);
}

# ── Unix (Linux/macOS) ──────────────────────────────────────────
sub run_unix {
    my ($mode, $bindir) = @_;

    my $home = $ENV{HOME} // die "ERROR: \$HOME is not set\n";
    my $shell_rc;
    if (defined $ENV{ZSH_VERSION} || (defined $ENV{SHELL} && $ENV{SHELL} =~ m{/zsh$})) {
        $shell_rc = "$home/.zshrc";
    } elsif (-f "$home/.bashrc") {
        $shell_rc = "$home/.bashrc";
    } else {
        $shell_rc = "$home/.profile";
    }

    # Make the rc line $HOME-relative so it stays portable across machines.
    my $bindir_rel = $bindir;
    $bindir_rel =~ s|^\Q$home\E/?||;

    # Detect whether $bindir is already on PATH-from-rc.
    my $already_path = 0;
    if (-f $shell_rc && open my $fh, '<', $shell_rc) {
        while (my $line = <$fh>) {
            if (index($line, $bindir_rel) >= 0) { $already_path = 1; last }
        }
        close $fh;
    }

    # Find candidate launchers and the symlinks we'd create.
    # fix-batch B3 (red-team MEDIUM-4): bsd_glob, NOT the builtin glob() --
    # the builtin word-splits its PATTERN on whitespace, so any install path
    # containing a space (a common Windows shape, "C:\Users\John Smith\...")
    # silently returned the wrong/empty result, disabling chmod and
    # extensionless-alias creation for that whole install with no error.
    my @launchers = bsd_glob("$bindir/*.sh");
    my @symlinks_needed;
    for my $launcher (@launchers) {
        my $name = basename($launcher);
        my $stripped = $name; $stripped =~ s/\.sh$//;
        my $link = "$bindir/$stripped";
        push @symlinks_needed, $link unless -e $link;
    }

    if ($mode eq 'plan') {
        if ($already_path) {
            print "  PATH: \$HOME/$bindir_rel already present in $shell_rc\n";
        } else {
            print "  PATH: would append `export PATH=\"\$HOME/$bindir_rel:\$PATH\"` to $shell_rc\n";
        }
        if (@launchers) {
            print "  chmod: would mark "
                . scalar(@launchers)
                . " *.sh launchers executable\n";
        }
        if (@symlinks_needed) {
            print "  symlinks: would create "
                . join(', ', map { basename($_) } @symlinks_needed)
                . " in $bindir\n";
        }
        return;
    }

    # apply
    for my $launcher (@launchers) {
        chmod 0755, $launcher;
    }
    for my $link (@symlinks_needed) {
        my $name = basename($link);
        symlink "${name}.sh", $link
            or warn "  symlink $link -> ${name}.sh failed: $!\n";
    }

    if ($already_path) {
        print "  PATH: \$HOME/$bindir_rel already present in $shell_rc\n";
    } else {
        open my $fh, '>>', $shell_rc
            or die "ERROR: cannot append to $shell_rc: $!\n";
        print $fh "\n# ccpraxis: $bindir_rel\n";
        print $fh "export PATH=\"\$HOME/$bindir_rel:\$PATH\"\n";
        close $fh;
        print "  PATH: appended \$HOME/$bindir_rel to $shell_rc\n";
    }
}

# ── Windows ─────────────────────────────────────────────────────
sub run_windows {
    my ($mode, $bindir) = @_;

    # Normalize bindir to Windows form. From Git Bash, getcwd / args may
    # be /c/Users/... — flip to C:\Users\... so the registry value is the
    # form Windows tools expect. Uppercase the drive letter for visual
    # consistency with what Windows itself writes.
    my $bindir_win = $bindir;
    $bindir_win =~ s|^/([a-zA-Z])/|uc($1) . ':/'|e;
    $bindir_win =~ s|^([a-zA-Z]):|uc($1) . ':'|e;
    $bindir_win =~ s|/|\\|g;
    $bindir_win =~ s|\\+$||;

    my $current_path     = ps_get_env('PATH', 'User')    // '';
    my $user_pathext     = ps_get_env('PATHEXT', 'User');
    my $system_pathext   = ps_get_env('PATHEXT', 'Machine') // '';

    my $already_path = 0;
    for my $entry (split /;/, $current_path) {
        my $e = $entry; $e =~ s|\\+$||;
        if (lc($e) eq lc($bindir_win)) { $already_path = 1; last }
    }

    my $existing_pathext = defined $user_pathext ? $user_pathext : $system_pathext;
    my $has_ps1 = 0;
    for my $ext (split /;/, $existing_pathext) {
        if (uc($ext) eq '.PS1') { $has_ps1 = 1; last }
    }

    if ($mode eq 'plan') {
        if ($already_path) {
            print "  PATH: $bindir_win already in user PATH (HKCU\\Environment)\n";
        } else {
            print "  PATH: would prepend $bindir_win to user PATH (HKCU\\Environment)\n";
        }
        if ($has_ps1) {
            print "  PATHEXT: .PS1 already present (no admin needed)\n";
        } else {
            print "  PATHEXT: would add .PS1 to user PATHEXT (HKCU\\Environment, no admin needed)\n";
        }
        return;
    }

    # apply
    # fix-batch B2 (red-team HIGH-3): snapshot the CURRENT User PATH to disk
    # before the first registry write this run might make -- the safety net
    # the ledger's own BINDING SAFETY CONSTRAINT and the user-global
    # CLAUDE.md's "Modifying the Windows User PATH" section require. Taken
    # unconditionally (even when already_path is true and this particular
    # branch writes nothing) because PATHEXT below can still be the first
    # write of the run.
    snapshot_user_path_once($current_path);

    if ($already_path) {
        print "  PATH: $bindir_win already in user PATH\n";
    } else {
        my $new_path = length($current_path) ? "$bindir_win;$current_path" : $bindir_win;
        ps_set_env('PATH', $new_path, 'User');
        print "  PATH: prepended $bindir_win to user PATH\n";
    }

    if ($has_ps1) {
        print "  PATHEXT: .PS1 already present\n";
    } else {
        # Setting a User PATHEXT entirely shadows Machine — seed from Machine
        # if the user has none so we don't narrow what the user can run.
        my $base = defined $user_pathext ? $user_pathext : $system_pathext;
        my $new_ext = length($base) ? "$base;.PS1" : '.PS1';
        ps_set_env('PATHEXT', $new_ext, 'User');
        print "  PATHEXT: added .PS1\n";
    }
}

# Read a registry-backed environment variable via powershell.exe. Returns
# the value as a UTF-8 byte string or undef if nothing was set.
#
# PowerShell's stdout encoding defaults to the console codepage (often
# CP437 / CP1252), which mangles non-ASCII bytes (e.g. a `é` in a Windows
# username) before we ever see them. We dodge the entire issue by having
# PowerShell base64-encode the value (UTF-8 bytes) on its side and we
# decode on ours — symmetric with ps_set_env.
# fix-batch B2 (red-team HIGH-3), testability seam ONLY: if
# CCPRAXIS_TEST_POWERSHELL_GET_ARGV / CCPRAXIS_TEST_POWERSHELL_SET_ARGV are
# set (\x1f-separated argv), ps_get_env/ps_set_env exec that instead of the
# real powershell.exe -- lets a test simulate a read failure, or intercept
# a write, without ever touching this host's real registry or requiring a
# fake native .exe. Unset (the default, every real install run) -> the
# real powershell.exe command line, byte-for-byte as before this fix.

# Read a registry-backed environment variable via powershell.exe. Returns
# the value as a UTF-8 byte string or undef if nothing was set.
#
# PowerShell's stdout encoding defaults to the console codepage (often
# CP437 / CP1252), which mangles non-ASCII bytes (e.g. a `é` in a Windows
# username) before we ever see them. We dodge the entire issue by having
# PowerShell base64-encode the value (UTF-8 bytes) on its side and we
# decode on ours — symmetric with ps_set_env.
#
# fix-batch B2 (red-team HIGH-3): the child's exit status is now checked.
# Previously a failed read (missing powershell.exe, a Restricted execution
# policy, a garbled read) silently produced an empty string, which the only
# caller (run_windows) laundered into "the user has no User PATH" -- and a
# subsequent ps_set_env could then overwrite the ENTIRE User-scope PATH
# with just the new bin dir, destroying every other entry, with no
# snapshot. An unreadable PATH must abort the install, never be treated as
# empty.
sub ps_get_env {
    my ($name, $scope) = @_;
    require MIME::Base64;
    my $cmd = '$v = [Environment]::GetEnvironmentVariable(' . "'$name','$scope'" . '); '
            . 'if ($null -ne $v) { '
            .   '[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($v)) '
            . '}';
    my @argv = $ENV{CCPRAXIS_TEST_POWERSHELL_GET_ARGV}
        ? split(/\x1f/, $ENV{CCPRAXIS_TEST_POWERSHELL_GET_ARGV})
        : ('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $cmd);
    open my $fh, '-|', @argv
        or die "ERROR: cannot exec powershell.exe: $!\n";
    my $b64 = do { local $/; <$fh> };
    close $fh;
    if ($?) {
        die "ERROR: powershell.exe exited with status $? while reading $scope\\$name -- "
          . "refusing to treat an unreadable PATH as empty (that would risk overwriting "
          . "every existing PATH entry on the next write). Aborting.\n";
    }
    return undef unless defined $b64;
    $b64 =~ s/\s+//g;
    return undef unless length $b64;
    my $bytes = MIME::Base64::decode_base64($b64);
    return length($bytes) ? $bytes : undef;
}

# fix-batch B2 (red-team HIGH-3): write a timestamped snapshot of the
# CURRENT User PATH to disk before the first registry write this run might
# make -- the safety net the ledger's BINDING SAFETY CONSTRAINT and the
# user-global CLAUDE.md's "Modifying the Windows User PATH" section
# require of any code that writes Windows registry PATH values. Fires at
# most once per run (idempotent within a process). $HOME is honoured (not
# hardcoded) so an isolated test run never touches the real snapshot dir.
my $SNAPSHOT_TAKEN = 0;
sub snapshot_user_path_once {
    my ($current_path) = @_;
    return if $SNAPSHOT_TAKEN;
    $SNAPSHOT_TAKEN = 1;
    my $home = $ENV{HOME};
    return unless defined $home && length $home; # nothing sane to snapshot into
    my $dir = "$home/.claude/.path-snapshots";
    unless (-d $dir) {
        require File::Path;
        File::Path::make_path($dir);
    }
    my $ts   = strftime('%Y%m%dT%H%M%SZ', gmtime);
    my $file = "$dir/$ts.txt";
    if (open my $fh, '>:raw', $file) {
        print $fh (defined $current_path ? $current_path : '');
        close $fh;
        print "  snapshot: current User PATH saved to $file\n";
    } else {
        warn "  WARNING: could not write PATH snapshot to $file: $!\n";
    }
}

# Write a registry-backed environment variable via powershell.exe. The
# value can legitimately contain `;`, `(`, `)`, etc. — to dodge every PS
# quoting concern we base64-encode the bytes in Perl and decode in
# PowerShell.
#
# IMPORTANT: $value is already a UTF-8 byte string (Git Bash paths are
# UTF-8, and ps_get_env returns base64-decoded UTF-8 bytes). Do NOT call
# Encode::encode here — that would treat each existing UTF-8 byte as a
# Latin-1 character and re-encode it, producing `Ã©` instead of `é` on
# each run. We pass the raw bytes through.
sub ps_set_env {
    my ($name, $value, $scope) = @_;
    my $b64 = encode_base64($value, '');   # no newlines
    my $cmd = "[Environment]::SetEnvironmentVariable("
            . "'$name', "
            . "[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')), "
            . "'$scope')";
    my @argv = $ENV{CCPRAXIS_TEST_POWERSHELL_SET_ARGV}
        ? split(/\x1f/, $ENV{CCPRAXIS_TEST_POWERSHELL_SET_ARGV})
        : ('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $cmd);
    my $rc = system(@argv);
    die "ERROR: powershell.exe SetEnvironmentVariable failed (rc=$rc)\n" if $rc != 0;
}
