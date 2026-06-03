#!/usr/bin/env perl
# install-skills.pl — link every <repo>/skills/<name>/ into ~/.claude/skills/.
#
# Two modes (matching the _install-bin-helper.pl convention):
#   perl install-skills.pl plan      # describe what would change
#   perl install-skills.pl apply     # apply the changes
#
# Linux/macOS: uses Perl's `symlink` builtin.
# Windows:     uses `cmd /c mklink /J` — a directory junction. Junctions
#              are reparse points that need no SeCreateSymbolicLink
#              privilege and no Developer Mode, unlike real symlinks. They
#              work transparently for filesystem reads by Node (Claude
#              Code) and any other consumer that doesn't introspect
#              reparse points.
#
# Idempotency:
#   - plan mode best-effort detects already-linked-correctly entries and
#     reports them as `[ok]`. False negatives are harmless because apply
#     is nuke-and-recreate (safe re-run).
#   - apply mode unconditionally removes the existing target and recreates
#     the link. This converges from any prior state (plain copy, stale
#     symlink, missing).

use strict;
use warnings;
use FindBin qw($Bin);
use Cwd qw(abs_path);
use File::Spec;
use File::Path qw(remove_tree make_path);
use MIME::Base64 qw(encode_base64 decode_base64);

# Raw byte I/O — paths flowing through Git Bash carry UTF-8 bytes; a :utf8
# layer would double-encode them on display. Matches _install-bin-helper.pl.
binmode STDOUT, ':raw';
binmode STDERR, ':raw';

my $mode = shift @ARGV // '';
unless ($mode =~ /^(plan|apply)$/) {
    die "usage: $0 <plan|apply>\n";
}

# ── Locate source and target ──────────────────────────────────────
my $home = $ENV{HOME} // $ENV{USERPROFILE}
    or die "ERROR: neither \$HOME nor %USERPROFILE% is set\n";

# $Bin is .../ccpraxis/scripts; one up is the repo root. abs_path collapses
# the `..` so the path we display (and store inside Windows junctions) is
# a clean absolute path.
my $repo_root  = abs_path(File::Spec->catdir($Bin, '..'))
    // die "ERROR: cannot resolve repo root from $Bin\n";
my $skills_src = File::Spec->catdir($repo_root, 'skills');
my $skills_dst = File::Spec->catdir($home, '.claude', 'skills');

die "ERROR: $skills_src does not exist\n" unless -d $skills_src;

# `$^O eq 'MSWin32'` only catches Strawberry/ActivePerl. Git Bash's bundled
# perl reports 'cygwin' or 'msys' but the host IS Windows and we want
# native junctions Claude Code can follow. Treat all three as Windows.
my $is_windows = ($^O eq 'MSWin32' || $^O eq 'cygwin' || $^O eq 'msys') ? 1 : 0;

# ── Enumerate skills in the repo ──────────────────────────────────
opendir(my $dh, $skills_src) or die "ERROR: opendir $skills_src: $!\n";
my @skills = sort
    grep { $_ !~ /^\.\.?$/ && -d File::Spec->catdir($skills_src, $_) }
    readdir $dh;
closedir $dh;

unless (@skills) {
    print "No skills under $skills_src — nothing to do.\n";
    exit 0;
}

# ── Classify each skill ───────────────────────────────────────────
my @actions;  # [ name, action, src, dst ]
for my $name (@skills) {
    my $src = File::Spec->catdir($skills_src, $name);
    my $dst = File::Spec->catdir($skills_dst, $name);
    push @actions, [ $name, classify_target($src, $dst), $src, $dst ];
}

# ── plan mode ─────────────────────────────────────────────────────
if ($mode eq 'plan') {
    print "install-skills.pl PLAN\n";
    print "  source: $skills_src\n";
    print "  target: $skills_dst\n";
    print "  method: " . ($is_windows ? "directory junction (via PowerShell New-Item)" : "Perl symlink") . "\n";
    print "\n";

    my $changes = 0;
    for my $a (@actions) {
        my ($name, $action) = @$a;
        if    ($action eq 'ok')                 { print "  [ok]      $name\n" }
        elsif ($action eq 'create')             { print "  [create]  $name\n"; $changes++ }
        elsif ($action eq 'replace-stale-link') { print "  [replace] $name (link points elsewhere)\n"; $changes++ }
        elsif ($action eq 'replace-copy')       { print "  [replace] $name (currently a plain dir/copy)\n"; $changes++ }
        elsif ($action eq 'replace-file')       { print "  [replace] $name (currently a plain file)\n"; $changes++ }
    }

    print "\n";
    if ($changes) {
        print "  $changes skill(s) to (re)link. Re-run with `apply`.\n";
    } else {
        print "  Nothing to do — all skills are already linked correctly.\n";
    }
    exit 0;
}

# ── apply mode ────────────────────────────────────────────────────
make_path($skills_dst) unless -d $skills_dst;

my $applied   = 0;
my $skipped   = 0;
my $failed    = 0;

for my $a (@actions) {
    my ($name, $action, $src, $dst) = @$a;

    if ($action eq 'ok') {
        $skipped++;
        next;
    }

    # Remove whatever's at $dst.
    if (-l $dst) {
        unless (unlink $dst) {
            warn "  ERROR: unlink $dst: $!\n";
            $failed++;
            next;
        }
    } elsif (-e $dst) {
        # Plain dir/copy/file — remove recursively.
        my $err;
        remove_tree($dst, { error => \$err });
        if ($err && @$err) {
            my $msg = join('; ', map { my ($k, $v) = %$_; "$k: $v" } @$err);
            warn "  ERROR: remove_tree $dst: $msg\n";
            $failed++;
            next;
        }
    }

    if (make_link($src, $dst)) {
        print "  linked $name\n";
        $applied++;
    } else {
        warn "  ERROR: failed to link $name ($src → $dst)\n";
        $failed++;
    }
}

print "\n";
print "  applied: $applied, already ok: $skipped";
print ", failed: $failed" if $failed;
print "\n";

exit($failed ? 1 : 0);

# ── Helpers ───────────────────────────────────────────────────────

sub classify_target {
    my ($src, $dst) = @_;

    return 'create' unless -l $dst || -e $dst;

    if ($is_windows) {
        # On Windows we ignore `-l` + `readlink` even though Cygwin Perl
        # reports junctions as symlinks — `readlink` then translates the
        # NTFS target back through Cygwin's mount table (e.g. C:\...\Temp\
        # → /tmp/...), which can't be compared to our source path. Use
        # PowerShell Get-Item, which returns the on-disk target verbatim.
        my $target = ps_get_link_target($dst);
        if (defined $target) {
            return 'ok' if paths_eq($target, $src);
            return 'replace-stale-link';
        }
        return -d $dst ? 'replace-copy' : 'replace-file';
    }

    if (-l $dst) {
        my $cur = readlink $dst;
        return 'ok' if defined $cur && paths_eq($cur, $src);
        return 'replace-stale-link';
    }
    return -d $dst ? 'replace-copy' : 'replace-file';
}

sub paths_eq {
    my ($a, $b) = @_;
    return 0 unless defined $a && defined $b;
    if ($is_windows) {
        # Route both through to_win_path so /c/Users/... and C:\Users\...
        # normalize to the same shape, then compare case-insensitively.
        return lc(to_win_path($a)) eq lc(to_win_path($b));
    }
    return File::Spec->canonpath($a) eq File::Spec->canonpath($b);
}

# Returns the reparse-point target path as a UTF-8 byte string if $dst is
# a junction or symbolic link, undef otherwise.
#
# Round-trips paths as base64-encoded UTF-8 bytes on BOTH sides — input
# (so PowerShell decodes the path string correctly regardless of how the
# argv was encoded by the CRT) and output (so the returned target survives
# PowerShell's OEM-codepage stdout, which mangles non-ASCII like `é` into
# `?`/`�`). Same pattern as ps_get_env in _install-bin-helper.pl.
sub ps_get_link_target {
    my $dst = shift;
    return undef unless $is_windows;

    my $dst_b64 = encode_base64(to_win_path($dst), '');

    my $ps = <<"PS";
\$dst = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$dst_b64'))
try {
    \$i = Get-Item -LiteralPath \$dst -Force -ErrorAction Stop
    if (\$i.LinkType -eq 'Junction' -or \$i.LinkType -eq 'SymbolicLink') {
        \$bytes = [Text.Encoding]::UTF8.GetBytes([string]\$i.Target)
        [Convert]::ToBase64String(\$bytes)
    }
} catch { }
PS

    open my $fh, '-|', 'powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $ps
        or return undef;
    my $b64 = do { local $/; <$fh> };
    close $fh;
    return undef unless defined $b64;
    $b64 =~ s/\s+//g;
    return undef unless length $b64;
    my $bytes = decode_base64($b64);
    return length($bytes) ? $bytes : undef;
}

sub make_link {
    my ($src, $dst) = @_;

    if ($is_windows) {
        # Native junction — needs no privileges, transparent to Node/Claude
        # Code. Created via PowerShell; paths are passed as base64-encoded
        # UTF-8 bytes so non-ASCII chars (e.g. `é` in a Windows username)
        # survive the argv encoding regardless of Perl flavor (Strawberry's
        # CRT uses CP1252 by default; Cygwin's uses UTF-8). Same pattern as
        # ps_set_env in _install-bin-helper.pl.
        my $src_b64 = encode_base64(to_win_path($src), '');
        my $dst_b64 = encode_base64(to_win_path($dst), '');
        my $ps = <<"PS";
\$src = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$src_b64'))
\$dst = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$dst_b64'))
try {
    New-Item -ItemType Junction -Path \$dst -Target \$src -ErrorAction Stop | Out-Null
} catch {
    [Console]::Error.WriteLine(\$_.Exception.Message)
    exit 1
}
PS
        my $rc = system('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $ps);
        return $rc == 0 && -d $dst;
    }

    return symlink($src, $dst) ? 1 : 0;
}

# Convert a path that may be in Cygwin/MSYS POSIX form (/c/Users/...) into
# Windows form (C:\Users\...) for consumption by cmd.exe builtins like
# mklink and fsutil. Paths already in Windows form (C:/... or C:\...) are
# normalized to use backslashes. UNC paths and other oddities pass through
# with just the slash translation.
sub to_win_path {
    my $p = shift;
    return $p unless defined $p && length $p;
    if ($p =~ m{^/([a-zA-Z])(/.*)?$}) {
        my $drive = uc $1;
        my $rest  = $2 // '';
        $rest =~ s{/}{\\}g;
        return "${drive}:${rest}";
    }
    (my $q = $p) =~ s{/}{\\}g;
    return $q;
}
